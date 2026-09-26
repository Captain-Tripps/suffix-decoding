# Gate test: custom suffix-sycl llama-server (MTP-only) vs stock b10488 Qwen3.8 baseline.
# Assumes llama-swap already unloaded (cards free). Restores gpt-oss-120b at the end.
$ErrorActionPreference = "Stop"
$repo   = Split-Path $PSScriptRoot -Parent
$outDir = Join-Path $repo "results"
$stamp  = Get-Date -Format "yyyyMMdd-HHmmss"
$outFile = Join-Path $outDir "gate-suffixbin-mtp-$stamp.jsonl"
$exe = "C:\Users\jstaples2\AI\Runtimes\llama.cpp\suffix-sycl\llama-server.exe"
$port = 9099
$swap = "http://100.89.126.50:8080"
$restoreModel = "gpt-oss-120b"

$oneapi = "C:\Program Files (x86)\Intel\oneAPI"
$env:Path = (@(
  "$oneapi\compiler\latest\bin",
  "$oneapi\mkl\latest\bin",
  "$oneapi\dnnl\latest\bin",
  "$oneapi\tbb\latest\bin",
  "$oneapi\umf\latest\bin",
  "$oneapi\ocloc\latest\bin",
  (Split-Path $exe -Parent)
) -join ";") + ";" + $env:Path
$env:UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS = "1"
$env:ZES_ENABLE_SYSMAN = "1"
$env:GGML_SYCL_ENABLE_VMM = "0"
# oneAPI 2026 DPC++ picks a non-Level-Zero UR adapter by default on this box;
# force Level Zero so SYCL sees the B70s and their free memory correctly.
$env:ONEAPI_DEVICE_SELECTOR = "level_zero:*"

$args = @(
  "-m","C:\models\bartowski\Qwen3.8-27B-GGUF\Qwen3.8-27B-Q8_0.gguf",
  "--mmproj","C:\models\bartowski\Qwen3.8-27B-GGUF\mmproj-F16.gguf",
  "--image-min-tokens","1024",
  "-ngl","99","-np","1","-c","131072","-t","16",
  "--load-mode","dio","-ctk","q4_0","-ctv","q4_0",
  "-b","2048","-ub","512","-fa","on",
  "--jinja","--reasoning","off",
  "--spec-type","draft-mtp","--spec-draft-n-max","3",
  "--metrics","--host","127.0.0.1","--port","$port"
)

$prompts = @(
  @{ name="warmup";      text="Reply with exactly: warmup."; n=16 },
  @{ name="easy_count";  text="Count from 1 to 25, comma-separated, then stop."; n=80 },
  @{ name="hard_code";   text="Write a complete Python function that merges two sorted lists into one sorted list without using heapq or sort. Include a brief comment. No extra prose."; n=180 },
  @{ name="warm_repeat"; text="Same task again, from scratch: write a complete Python function that merges two sorted lists into one sorted list without using heapq or sort. Include a brief comment. No extra prose."; n=180 },
  @{ name="hard_reason"; text="A farmer has 17 sheep. All but 9 die. How many are left? Give a one-sentence explanation then the number."; n=64 }
)

$srvLog = Join-Path $outDir "gate-suffixbin-server-$stamp.log"
Write-Host "launching custom server on :$port  (log: $srvLog)"
$proc = Start-Process -FilePath $exe -ArgumentList $args -NoNewWindow -PassThru `
          -RedirectStandardError $srvLog -RedirectStandardOutput "$srvLog.out"

try {
  $deadline = (Get-Date).AddMinutes(10)
  do {
    Start-Sleep 3
    try { $h = (Invoke-WebRequest "http://127.0.0.1:$port/health" -UseBasicParsing -TimeoutSec 5).StatusCode } catch { $h = 0 }
  } while ($h -ne 200 -and (Get-Date) -lt $deadline -and -not $proc.HasExited)
  if ($h -ne 200) { throw "server did not become healthy (proc exited: $($proc.HasExited))" }
  Write-Host "healthy. benching..."

  foreach ($p in $prompts) {
    $body = @{
      messages = @(@{ role="user"; content=$p.text })
      max_tokens = $p.n; temperature = 0
      chat_template_kwargs = @{ enable_thinking = $false }
    } | ConvertTo-Json -Depth 6
    $r = Invoke-RestMethod "http://127.0.0.1:$port/v1/chat/completions" -Method POST -Body $body -ContentType "application/json" -TimeoutSec 300
    $t = $r.timings
    $row = [ordered]@{
      ts=(Get-Date).ToString("o"); bin="suffix-sycl"; spec="draft-mtp n3"; prompt=$p.name
      prompt_n=$t.prompt_n; prompt_tps=$t.prompt_per_second
      predicted_n=$t.predicted_n; predicted_tps=$t.predicted_per_second
      draft_n=$t.draft_n; draft_n_accepted=$t.draft_n_accepted
    }
    ($row | ConvertTo-Json -Compress) | Add-Content $outFile
    Write-Host ("{0,-12} pp={1,6:N1}  tg={2,6:N1}  n={3,-4} draft={4}/{5}" -f `
      $p.name, $row.prompt_tps, $row.predicted_tps, $row.predicted_n, $row.draft_n_accepted, $row.draft_n)
  }
}
finally {
  Write-Host "stopping custom server..."
  if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
  Start-Sleep 5
  Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep 3
  Write-Host "restoring $restoreModel via llama-swap..."
  try {
    $b = @{ messages=@(@{role="user";content="ping"}); max_tokens=4; model=$restoreModel } | ConvertTo-Json -Depth 5
    Invoke-RestMethod "$swap/v1/chat/completions" -Method POST -Body $b -ContentType "application/json" -TimeoutSec 300 | Out-Null
    $dl = (Get-Date).AddMinutes(10)
    do { Start-Sleep 3; $run = (Invoke-RestMethod "$swap/running" -TimeoutSec 5).running }
    while (-not (@($run) | Where-Object { $_.model -eq $restoreModel -and $_.state -eq "ready" }) -and (Get-Date) -lt $dl)
    Write-Host "restore state: $(($run | ConvertTo-Json -Compress))"
  } catch { Write-Warning "RESTORE FAILED: $_  -- reload $restoreModel manually" }
}

Write-Host "`n==== gate result ===="
Write-Host "baseline b10488 qwen3.8-27b MTP n3:  easy 43.98 | code 43.41 | warm 43.26 | reason 32.35 t/s"
Write-Host "wrote $outFile"
