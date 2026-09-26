# Option 2: isolate base decode. Run BOTH binaries no-spec, same flags/prompts.
# If custom also lags b10488 here -> base decode regressed (FA shim).
# If custom matches -> only the MTP verify path is slow.
# Also runs custom with -fa off to further pin flash-attention.
$ErrorActionPreference = "Stop"
$repo   = Split-Path $PSScriptRoot -Parent
$outDir = Join-Path $repo "results"
$stamp  = Get-Date -Format "yyyyMMdd-HHmmss"
$outFile = Join-Path $outDir "gate-nospec-$stamp.jsonl"
$swap = "http://100.89.126.50:8080"
$restoreModel = "gpt-oss-120b"
$port = 9099

$b10488 = "C:\Users\jstaples2\AI\Runtimes\llama.cpp\b10488\llama-server.exe"
$custom = "C:\Users\jstaples2\AI\Runtimes\llama.cpp\suffix-sycl\llama-server.exe"

$oneapi = "C:\Program Files (x86)\Intel\oneAPI"
$oneapiPaths = @(
  "$oneapi\compiler\latest\bin","$oneapi\mkl\latest\bin","$oneapi\dnnl\latest\bin",
  "$oneapi\tbb\latest\bin","$oneapi\umf\latest\bin","$oneapi\ocloc\latest\bin"
) -join ";"
$origPath = $env:Path
$env:UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS = "1"
$env:ZES_ENABLE_SYSMAN = "1"
$env:GGML_SYCL_ENABLE_VMM = "0"

$prompts = @(
  @{ name="warmup";      text="Reply with exactly: warmup."; n=16 },
  @{ name="easy_count";  text="Count from 1 to 25, comma-separated, then stop."; n=80 },
  @{ name="hard_code";   text="Write a complete Python function that merges two sorted lists into one sorted list without using heapq or sort. Include a brief comment. No extra prose."; n=180 },
  @{ name="warm_repeat"; text="Same task again, from scratch: write a complete Python function that merges two sorted lists into one sorted list without using heapq or sort. Include a brief comment. No extra prose."; n=180 },
  @{ name="hard_reason"; text="A farmer has 17 sheep. All but 9 die. How many are left? Give a one-sentence explanation then the number."; n=64 }
)

function Base-Args([string]$fa) {
  @(
    "-m","C:\models\bartowski\Qwen3.8-27B-GGUF\Qwen3.8-27B-Q8_0.gguf",
    "--mmproj","C:\models\bartowski\Qwen3.8-27B-GGUF\mmproj-F16.gguf",
    "--image-min-tokens","1024",
    "-ngl","99","-np","1","-c","131072","-t","16",
    "--load-mode","dio","-ctk","q4_0","-ctv","q4_0",
    "-b","2048","-ub","512","-fa",$fa,
    "--jinja","--reasoning","off",
    "--spec-type","none",
    "--metrics","--host","127.0.0.1","--port","$port"
  )
}

function Run-One([string]$label,[string]$exe,[string]$fa) {
  Write-Host "==== $label ===="
  $slog = Join-Path $outDir "gate-nospec-$label-$stamp.log"
  $p = Start-Process -FilePath $exe -ArgumentList (Base-Args $fa) -NoNewWindow -PassThru `
        -RedirectStandardError $slog -RedirectStandardOutput "$slog.out"
  try {
    $dl = (Get-Date).AddMinutes(10)
    do { Start-Sleep 3; try { $h=(Invoke-WebRequest "http://127.0.0.1:$port/health" -UseBasicParsing -TimeoutSec 5).StatusCode } catch { $h=0 } }
    while ($h -ne 200 -and (Get-Date) -lt $dl -and -not $p.HasExited)
    if ($h -ne 200) { throw "$label did not become healthy (exited: $($p.HasExited))" }
    foreach ($pr in $prompts) {
      $body = @{ messages=@(@{role="user";content=$pr.text}); max_tokens=$pr.n; temperature=0
                 chat_template_kwargs=@{ enable_thinking=$false } } | ConvertTo-Json -Depth 6
      $r = Invoke-RestMethod "http://127.0.0.1:$port/v1/chat/completions" -Method POST -Body $body -ContentType "application/json" -TimeoutSec 300
      $t = $r.timings
      $row = [ordered]@{ ts=(Get-Date).ToString("o"); label=$label; prompt=$pr.name
        prompt_tps=$t.prompt_per_second; predicted_n=$t.predicted_n; predicted_tps=$t.predicted_per_second }
      ($row | ConvertTo-Json -Compress) | Add-Content $outFile
      Write-Host ("{0,-14} {1,-12} pp={2,6:N1}  tg={3,6:N1}  n={4}" -f $label,$pr.name,$row.prompt_tps,$row.predicted_tps,$row.predicted_n)
    }
  } finally {
    if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    Start-Sleep 5
    Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep 3
  }
}

Write-Host "unloading llama-swap model..."
Invoke-WebRequest "$swap/api/models/unload" -Method POST -UseBasicParsing -TimeoutSec 20 | Out-Null
Start-Sleep 6

try {
  $env:Path = $origPath                       # b10488 ships its own DLLs
  Run-One "b10488-nospec" $b10488 "on"
  $env:Path = $oneapiPaths + ";" + (Split-Path $custom -Parent) + ";" + $origPath
  Run-One "custom-nospec" $custom "on"
  Run-One "custom-nospec-faoff" $custom "off"
}
finally {
  $env:Path = $origPath
  Write-Host "restoring $restoreModel..."
  try {
    $b = @{ messages=@(@{role="user";content="ping"}); max_tokens=4; model=$restoreModel } | ConvertTo-Json -Depth 5
    Invoke-RestMethod "$swap/v1/chat/completions" -Method POST -Body $b -ContentType "application/json" -TimeoutSec 300 | Out-Null
    $dl=(Get-Date).AddMinutes(10)
    do { Start-Sleep 3; $run=(Invoke-RestMethod "$swap/running" -TimeoutSec 5).running }
    while (-not (@($run)|?{$_.model -eq $restoreModel -and $_.state -eq "ready"}) -and (Get-Date) -lt $dl)
    Write-Host "restore: $(($run|ConvertTo-Json -Compress))"
  } catch { Write-Warning "RESTORE FAILED: $_" }
}
Write-Host "`nwrote $outFile"
