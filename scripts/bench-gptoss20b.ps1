# gpt-oss-20b Q8_0 spec-decoding bench on ONE B70. No native MTP -> model-free only.
# Configs: none / ngram-mod / suffix. Same agent-loop prompts, run in sequence so
# the ngram pool / suffix tree warm. Unloads gpt-oss-120b at start, restores at end.
$ErrorActionPreference = "Stop"
$repo   = Split-Path $PSScriptRoot -Parent
$outDir = Join-Path $repo "results"
$stamp  = Get-Date -Format "yyyyMMdd-HHmmss"
$outFile = Join-Path $outDir "bench-gptoss20b-$stamp.jsonl"
$exe  = "C:\Users\jstaples2\AI\Runtimes\llama.cpp\suffix-sycl\llama-server.exe"
$model = "D:\AI\LLM\Models\unsloth\gpt-oss-20b-GGUF\gpt-oss-20b-Q8_0.gguf"
$port = 9099
$swap = "http://100.89.126.50:8080"
$restoreModel = "gpt-oss-120b"

$env:Path = (Split-Path $exe -Parent) + ";C:\Program Files (x86)\Intel\oneAPI\ocloc\latest\bin;" + $env:Path
$env:UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS = "1"
$env:ZES_ENABLE_SYSMAN = "1"
$env:GGML_SYCL_ENABLE_VMM = "0"
$env:ONEAPI_DEVICE_SELECTOR = "level_zero:0"   # single card

$configs = @(
  @{ label="none";      spec=@("--spec-type","none") },
  @{ label="ngram-mod"; spec=@("--spec-type","ngram-mod") },
  @{ label="suffix";    spec=@("--spec-type","suffix") }
)

$q = '"'
$prompts = @(
  @{ name="json_1";  n=80;  text="Return ONLY valid JSON, no markdown: {${q}ok${q}: true, ${q}items${q}: [1, 2, 3], ${q}status${q}: ${q}done${q}}" }
  @{ name="json_2";  n=80;  text="Return ONLY valid JSON, no markdown: {${q}ok${q}: true, ${q}items${q}: [1, 2, 3], ${q}status${q}: ${q}done${q}}" }
  @{ name="json_3v"; n=80;  text="Return ONLY valid JSON, no markdown: {${q}ok${q}: true, ${q}items${q}: [4, 5, 6], ${q}status${q}: ${q}done${q}}" }
  @{ name="code_1";  n=200; text="Write a complete Python function that merges two sorted lists into one sorted list without using heapq or sort. Include a brief comment. No extra prose." }
  @{ name="code_2";  n=200; text="Write a complete Python function that merges two sorted lists into one sorted list without using heapq or sort. Include a brief comment. No extra prose." }
  @{ name="code_3";  n=200; text="Write a complete Python function that merges two sorted lists into one sorted list without using heapq or sort. Include a brief comment. No extra prose." }
  @{ name="refactor";n=240; text="Sounds good. Refactor that merge_sorted_lists function so a beginner can understand it. More comments, same behavior. Return only the code." }
)

$baseArgs = @(
  "-m",$model,
  "-ngl","99","-np","1","-c","65536","-t","16",
  "--load-mode","dio","-b","2048","-ub","512","-fa","on",
  "--jinja","--reasoning-budget","0",
  "--metrics","--host","127.0.0.1","--port","$port"
)

Write-Host "unloading llama-swap model..."
try { Invoke-WebRequest "$swap/api/models/unload" -Method POST -UseBasicParsing -TimeoutSec 20 | Out-Null } catch {}
$dl=(Get-Date).AddMinutes(3)
do { Start-Sleep 4; try { $run=@((Invoke-RestMethod "$swap/running" -TimeoutSec 5).running) } catch { $run=@() } } while ($run.Count -gt 0 -and (Get-Date) -lt $dl)
Start-Sleep 25

function Chat($text,$n) {
  $body = @{ messages=@(@{role="user";content=$text}); max_tokens=$n; temperature=0 } | ConvertTo-Json -Depth 6
  Invoke-RestMethod "http://127.0.0.1:$port/v1/chat/completions" -Method POST -Body $body -ContentType "application/json" -TimeoutSec 300
}

try {
  foreach ($cfg in $configs) {
    Write-Host "`n==== $($cfg.label) ===="
    $slog = Join-Path $outDir "bench-gptoss20b-$($cfg.label)-$stamp.log"
    $p = Start-Process -FilePath $exe -ArgumentList ($baseArgs + $cfg.spec) -NoNewWindow -PassThru `
          -RedirectStandardError $slog -RedirectStandardOutput "$slog.out"
    try {
      $d=(Get-Date).AddMinutes(10)
      do { Start-Sleep 3; try { $h=(Invoke-WebRequest "http://127.0.0.1:$port/health" -UseBasicParsing -TimeoutSec 5).StatusCode } catch { $h=0 } }
      while ($h -ne 200 -and (Get-Date) -lt $d -and -not $p.HasExited)
      if ($h -ne 200) { throw "$($cfg.label) unhealthy (exited: $($p.HasExited))" }
      Chat "Reply with exactly: ping." 8 | Out-Null
      foreach ($pr in $prompts) {
        $j = Chat $pr.text $pr.n
        $t = $j.timings
        $row = [ordered]@{ ts=(Get-Date).ToString("o"); model="gpt-oss-20b"; cfg=$cfg.label; prompt=$pr.name
          predicted_n=$t.predicted_n; tg=$t.predicted_per_second; pp=$t.prompt_per_second
          draft_n=$t.draft_n; draft_acc=$t.draft_n_accepted }
        ($row | ConvertTo-Json -Compress) | Add-Content $outFile
        $a = if ($t.draft_n) { "{0}/{1}" -f $t.draft_n_accepted,$t.draft_n } else { "-" }
        Write-Host ("  {0,-9} tg={1,6:N1}  n={2,-4} draft={3}" -f $pr.name,$row.tg,$row.predicted_n,$a)
      }
    } finally {
      if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force }
      Start-Sleep 6
    }
  }
}
finally {
  Write-Host "`nrestoring $restoreModel..."
  try {
    $b=@{ messages=@(@{role="user";content="ping"}); max_tokens=4; model=$restoreModel } | ConvertTo-Json -Depth 5
    Invoke-RestMethod "$swap/v1/chat/completions" -Method POST -Body $b -ContentType "application/json" -TimeoutSec 300 | Out-Null
    $d=(Get-Date).AddMinutes(10)
    do { Start-Sleep 3; $run=(Invoke-RestMethod "$swap/running" -TimeoutSec 5).running }
    while (-not (@($run)|?{$_.model -eq $restoreModel -and $_.state -eq "ready"}) -and (Get-Date) -lt $d)
    Write-Host "restore: $(($run|ConvertTo-Json -Compress))"
  } catch { Write-Warning "RESTORE FAILED: $_" }
}
Write-Host "`nwrote $outFile"
