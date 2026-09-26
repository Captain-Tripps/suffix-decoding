# Corpus-preload test THROUGH llama-swap (it manages model swap + VRAM cleanup).
# Generate Chapter 2 prose from its real beat plan. Compare:
#   A qwen3.8-27b            (MTP control)
#   B qwen3.8-27b-ngram      (best in-context method)
#   C qwen3.8-27b-suffix-corpus  WITH Heirloom Ch1 corpus
#   D qwen3.8-27b-suffix-corpus  corpus swapped to []  (no-corpus control)
$ErrorActionPreference = "Stop"
$repo   = Split-Path $PSScriptRoot -Parent
$outDir = Join-Path $repo "results"
$stamp  = Get-Date -Format "yyyyMMdd-HHmmss"
$outFile = Join-Path $outDir "bench-corpus-swap-$stamp.jsonl"
$swap    = "http://100.89.126.50:8080"
$corpusFile = "C:\llama-swap\corpus\current.json"

$book  = "C:\Users\jstaples2\Projects\Bespoke_Books\books\users\f0258f8d-a12b-47f1-b919-a67905c7a3e0\books\book_20260523_193139_810718_b5984b61"
$beats = [IO.File]::ReadAllText("$book\chapters\02\module3_output.md")   # UTF-8
$realCorpus = [IO.File]::ReadAllText($corpusFile)   # save to restore

$sys = "You are a cozy-fantasy novelist. Write warm, grounded prose. No preamble, no headings - just the chapter text."
$usr = "Here is the beat plan for Chapter 2 of 'Heirloom of the Ironwood Grove'. Write the chapter as flowing prose, about 1100 words, faithful to the beats and the established voice.`n`n$beats"

function Unload { try { Invoke-WebRequest "$swap/api/models/unload" -Method POST -UseBasicParsing -TimeoutSec 20 | Out-Null } catch {}
  $dl=(Get-Date).AddMinutes(3)
  do { Start-Sleep 4; try { $r=@((Invoke-RestMethod "$swap/running" -TimeoutSec 5).running) } catch { $r=@() } } while ($r.Count -gt 0 -and (Get-Date) -lt $dl)
  Start-Sleep 20 }

function Chat($model,$n) {
  $body = @{ model=$model; messages=@(@{role="system";content=$sys},@{role="user";content=$usr})
             max_tokens=$n; temperature=0.7; seed=1; chat_template_kwargs=@{ enable_thinking=$false } } | ConvertTo-Json -Depth 6
  $bytes = [Text.Encoding]::UTF8.GetBytes($body)
  Invoke-RestMethod "$swap/v1/chat/completions" -Method POST -Body $bytes -ContentType "application/json; charset=utf-8" -TimeoutSec 500
}

function Run($label,$model) {
  Write-Host "`n==== $label ($model) ===="
  try { Chat $model 8 | Out-Null } catch { Write-Warning "warmup: $_" }   # trigger load
  $dl=(Get-Date).AddMinutes(10)
  do { Start-Sleep 3; try { $st=((Invoke-RestMethod "$swap/running" -TimeoutSec 5).running | ? { $_.model -eq $model }).state } catch { $st=$null } }
  while ($st -ne "ready" -and (Get-Date) -lt $dl)
  foreach ($pass in 1,2) {
    $j = Chat $model 1400
    $t = $j.timings
    $txt = ""; if ($j.choices -and $j.choices[0].message.content) { $txt = $j.choices[0].message.content }
    $words = ($txt -split '\s+').Count
    $row = [ordered]@{ ts=(Get-Date).ToString("o"); label=$label; model=$model; pass=$pass
      predicted_n=$t.predicted_n; tg=$t.predicted_per_second; pp=$t.prompt_per_second
      draft_n=$t.draft_n; draft_acc=$t.draft_n_accepted; words=$words }
    ($row | ConvertTo-Json -Compress) | Add-Content $outFile
    $a = if ($t.draft_n) { "{0}/{1} ({2:P0})" -f $t.draft_n_accepted,$t.draft_n,($t.draft_n_accepted/[double]$t.draft_n) } else { "-" }
    Write-Host ("  pass{0}  tg={1,6:N1}  n={2,-4} words={3,-4} draft={4}" -f $pass,$row.tg,$row.predicted_n,$words,$a)
  }
}

try {
  Run "A mtp"           "qwen3.8-27b"
  Run "B ngram"         "qwen3.8-27b-ngram"
  Run "C suffix+corpus" "qwen3.8-27b-suffix-corpus"

  Write-Host "`n-- swapping corpus to [] and reloading for the no-corpus control --"
  Unload
  '[]' | Set-Content $corpusFile -NoNewline
  Run "D suffix+empty"  "qwen3.8-27b-suffix-corpus"
}
finally {
  # restore real corpus + leave qwen3.8-27b-ngram loaded (Atlas target)
  $realCorpus | Set-Content $corpusFile -NoNewline
  Write-Host "`nrestored $corpusFile; loading qwen3.8-27b-ngram..."
  try { Chat "qwen3.8-27b-ngram" 4 | Out-Null } catch {}
}
Write-Host "`nwrote $outFile"
