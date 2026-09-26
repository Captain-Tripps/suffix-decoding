# Bench --spec-type suffix on the custom oneAPI-2026 binary vs mtp / ngram-mod.
# All configs run on the SAME binary so ggml-sycl kernels are constant; only the
# CPU drafter changes. Prompts run in sequence within one server so the shared
# suffix tree / ngram pool warms (that's where suffix is supposed to pay).
# Unloads gpt-oss-120b at start, restores at end.
$ErrorActionPreference = "Stop"
$repo   = Split-Path $PSScriptRoot -Parent
$outDir = Join-Path $repo "results"
$stamp  = Get-Date -Format "yyyyMMdd-HHmmss"
$outFile = Join-Path $outDir "bench-suffix-$stamp.jsonl"
$exe  = "C:\Users\jstaples2\AI\Runtimes\llama.cpp\suffix-sycl\llama-server.exe"
$port = 9099
$swap = "http://100.89.126.50:8080"
$restoreModel = "gpt-oss-120b"

$env:Path = (Split-Path $exe -Parent) + ";C:\Program Files (x86)\Intel\oneAPI\ocloc\latest\bin;" + $env:Path
$env:UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS = "1"
$env:ZES_ENABLE_SYSMAN = "1"
$env:GGML_SYCL_ENABLE_VMM = "0"
$env:ONEAPI_DEVICE_SELECTOR = "level_zero:*"

$configs = @(
  @{ label="mtp";            spec=@("--spec-type","draft-mtp","--spec-draft-n-max","3") },
  @{ label="ngram+mtp";      spec=@("--spec-type","ngram-mod,draft-mtp","--spec-draft-n-max","3") },
  @{ label="suffix+mtp";     spec=@("--spec-type","suffix,draft-mtp","--spec-draft-n-max","3") },
  @{ label="suffix";         spec=@("--spec-type","suffix") }
)

$q = '"'
$prompts = @(
  @{ name="json_1";  n=80;  text="Return ONLY valid JSON, no markdown: {${q}ok${q}: true, ${q}items${q}: [1, 2, 3], ${q}status${q}: ${q}done${q}}" }
  @{ name="json_2";  n=80;  text="Return ONLY valid JSON, no markdown: {${q}ok${q}: true, ${q}items${q}: [1, 2, 3], ${q}status${q}: ${q}done${q}}" }
  @{ name="json_3v"; n=80;  text="Return ONLY valid JSON, no markdown: {${q}ok${q}: true, ${q}items${q}: [4, 5, 6], ${q}status${q}: ${q}done${q}}" }
  @{ name="code_1";  n=180; text="Write a complete Python function that merges two sorted lists into one sorted list without using heapq or sort. Include a brief comment. No extra prose." }
  @{ name="code_2";  n=180; text="Write a complete Python function that merges two sorted lists into one sorted list without using heapq or sort. Include a brief comment. No extra prose." }
  @{ name="code_3";  n=180; text="Write a complete Python function that merges two sorted lists into one sorted list without using heapq or sort. Include a brief comment. No extra prose." }
  @{ name="refactor";n=220; text="Sounds good. Refactor that merge_sorted_lists function so a beginner can understand it. More comments, same behavior. Return only the code." }
)

$baseArgs = @(
  "-m","C:\models\bartowski\Qwen3.8-27B-GGUF\Qwen3.8-27B-Q8_0.gguf",
  "--mmproj","C:\models\bartowski\Qwen3.8-27B-GGUF\mmproj-F16.gguf",
  "--image-min-tokens","1024",
  "-ngl","99","-np","1","-c","131072","-t","16",
  "--load-mode","dio","-ctk","q4_0","-ctv","q4_0",
  "-b","2048","-ub","512","-fa","on","--jinja","--reasoning","off",
  "--metrics","--host","127.0.0.1","--port","$port"
)

Write-Host "unloading llama-swap model..."
try { Invoke-WebRequest "$swap/api/models/unload" -Method POST -UseBasicParsing -TimeoutSec 20 | Out-Null } catch {}
$dl=(Get-Date).AddMinutes(3)
do { Start-Sleep 4; try { $run=@((Invoke-RestMethod "$swap/running" -TimeoutSec 5).running) } catch { $run=@() } } while ($run.Count -gt 0 -and (Get-Date) -lt $dl)
Start-Sleep 25

function Chat($text,$n) {
  $body = @{ messages=@(@{role="user";content=$text}); max_tokens=$n; temperature=0
             chat_template_kwargs=@{ enable_thinking=$false } } | ConvertTo-Json -Depth 6
  Invoke-RestMethod "http://127.0.0.1:$port/v1/chat/completions" -Method POST -Body $body -ContentType "application/json" -TimeoutSec 300
}

try {
  foreach ($cfg in $configs) {
    Write-Host "`n==== $($cfg.label) : $($cfg.spec -join ' ') ===="
    $slog = Join-Path $outDir "bench-suffix-$($cfg.label)-$stamp.log"
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
        $row = [ordered]@{ ts=(Get-Date).ToString("o"); cfg=$cfg.label; prompt=$pr.name
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
