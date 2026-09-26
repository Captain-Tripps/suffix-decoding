# Local proxy for the M4 cold-start: generate Chapter 2 prose from its beat plan,
# with the suffix tree pre-warmed from Chapter 1 prose + story bible + seed.
# Isolates the one thing ngram-mod structurally can't do (cross-call priming).
# 4 configs on the same custom binary; 2 calls each (cold + warm).
$ErrorActionPreference = "Stop"
$repo   = Split-Path $PSScriptRoot -Parent
$outDir = Join-Path $repo "results"
$stamp  = Get-Date -Format "yyyyMMdd-HHmmss"
$outFile = Join-Path $outDir "bench-corpus-$stamp.jsonl"
$exe  = "C:\Users\jstaples2\AI\Runtimes\llama.cpp\suffix-sycl\llama-server.exe"
$port = 9099
$swap = "http://100.89.126.50:8080"
$restoreModel = "qwen3.8-27b-ngram"   # Atlas points here; put it back when done

$book   = "C:\Users\jstaples2\Projects\Bespoke_Books\books\users\f0258f8d-a12b-47f1-b919-a67905c7a3e0\books\book_20260523_193139_810718_b5984b61"
$corpus = "C:\Users\JSTAPL~1\AppData\Local\Temp\claude\C--Users-jstaples2\19fe65ef-8a47-4e40-a15a-46cddaf5db78\scratchpad\corpus_ch1.json"
$beats  = Get-Content "$book\chapters\02\module3_output.md" -Raw

$env:Path = (Split-Path $exe -Parent) + ";C:\Program Files (x86)\Intel\oneAPI\ocloc\latest\bin;" + $env:Path
$env:UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS = "1"
$env:ZES_ENABLE_SYSMAN = "1"
$env:GGML_SYCL_ENABLE_VMM = "0"
$env:ONEAPI_DEVICE_SELECTOR = "level_zero:*"

$configs = @(
  @{ label="mtp";             spec=@("--spec-type","draft-mtp","--spec-draft-n-max","3") },
  @{ label="ngram+mtp";       spec=@("--spec-type","ngram-mod,draft-mtp","--spec-draft-n-max","3") },
  @{ label="suffix+mtp";      spec=@("--spec-type","suffix,draft-mtp","--spec-draft-n-max","3","--spec-suffix-min-match-len","16") },
  @{ label="suffix+corpus";   spec=@("--spec-type","suffix,draft-mtp","--spec-draft-n-max","3","--spec-suffix-min-match-len","16","--spec-suffix-corpus",$corpus) }
)

$sys = "You are a cozy-fantasy novelist. Write warm, grounded prose. No preamble, no headings - just the chapter text."
$usr = "Here is the beat plan for Chapter 2 of 'Heirloom of the Ironwood Grove'. Write the chapter as flowing prose, about 1100 words, staying faithful to the beats and the established voice.`n`n$beats"

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

function Chat($n) {
  $body = @{ messages=@(@{role="system";content=$sys},@{role="user";content=$usr}); max_tokens=$n; temperature=0.7; seed=1
             chat_template_kwargs=@{ enable_thinking=$false } } | ConvertTo-Json -Depth 6
  Invoke-RestMethod "http://127.0.0.1:$port/v1/chat/completions" -Method POST -Body $body -ContentType "application/json" -TimeoutSec 400
}

try {
  foreach ($cfg in $configs) {
    Write-Host "`n==== $($cfg.label) ===="
    $slog = Join-Path $outDir "bench-corpus-$($cfg.label)-$stamp.log"
    $p = Start-Process -FilePath $exe -ArgumentList ($baseArgs + $cfg.spec) -NoNewWindow -PassThru `
          -RedirectStandardError $slog -RedirectStandardOutput "$slog.out"
    try {
      $d=(Get-Date).AddMinutes(10)
      do { Start-Sleep 3; try { $h=(Invoke-WebRequest "http://127.0.0.1:$port/health" -UseBasicParsing -TimeoutSec 5).StatusCode } catch { $h=0 } }
      while ($h -ne 200 -and (Get-Date) -lt $d -and -not $p.HasExited)
      if ($h -ne 200) { throw "$($cfg.label) unhealthy (exited: $($p.HasExited))" }
      # confirm corpus load line for the corpus config
      if ($cfg.label -eq "suffix+corpus") {
        $ll = Get-Content $slog -Raw
        if ($ll -match "corpus.*pre-warm|loaded suffix corpus") { Write-Host "  [corpus load confirmed in log]" }
        else { Write-Host "  [WARN: no corpus-load line in log yet]" }
      }
      foreach ($pass in 1,2) {
        $j = Chat 1400
        $t = $j.timings
        $words = ($j.choices[0].message.content -split '\s+').Count
        $row = [ordered]@{ ts=(Get-Date).ToString("o"); cfg=$cfg.label; pass=$pass
          predicted_n=$t.predicted_n; tg=$t.predicted_per_second; pp=$t.prompt_per_second
          draft_n=$t.draft_n; draft_acc=$t.draft_n_accepted; words=$words }
        ($row | ConvertTo-Json -Compress) | Add-Content $outFile
        $a = if ($t.draft_n) { "{0}/{1} ({2:P0})" -f $t.draft_n_accepted,$t.draft_n,($t.draft_n_accepted/$t.draft_n) } else { "-" }
        Write-Host ("  pass{0}  tg={1,6:N1}  n={2,-4} words={3,-4} draft={4}" -f $pass,$row.tg,$row.predicted_n,$words,$a)
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
  } catch { Write-Warning "restore failed: $_" }
}
Write-Host "`nwrote $outFile"
