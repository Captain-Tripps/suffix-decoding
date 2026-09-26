# Does ngram-mod change the output vs plain MTP?
# temp 0 (greedy): spec decoding MUST produce byte-identical output. If it doesn't
# -> real bug (premature EOS acceptance = shorter chapters). If it does -> the
# temp>0 length differences are RNG-path divergence, not a bias.
# Also does a temp-0.7 seeded triple to measure the length spread.
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
$outDir = Join-Path $repo "results"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$swap = "http://100.89.126.50:8080"
$book = "C:\Users\jstaples2\Projects\Bespoke_Books\books\users\f0258f8d-a12b-47f1-b919-a67905c7a3e0\books\book_20260523_193139_810718_b5984b61"
$beats = [IO.File]::ReadAllText("$book\chapters\02\module3_output.md")
$sys = "You are a cozy-fantasy novelist. Write warm, grounded prose. No preamble, no headings - just the chapter text."
$usr = "Beat plan for Chapter 2 of 'Heirloom of the Ironwood Grove'. Write it as ~1100 words of flowing prose.`n`n$beats"

function Chat($model,$temp,$seed,$n) {
  $m = @{ model=$model; messages=@(@{role="system";content=$sys},@{role="user";content=$usr}); max_tokens=$n; temperature=$temp }
  if ($seed -ne $null) { $m.seed = $seed }
  $m.chat_template_kwargs = @{ enable_thinking = $false }
  $bytes = [Text.Encoding]::UTF8.GetBytes(($m | ConvertTo-Json -Depth 6))
  Invoke-RestMethod "$swap/v1/chat/completions" -Method POST -Body $bytes -ContentType "application/json; charset=utf-8" -TimeoutSec 500
}
function WaitReady($model) {
  try { Chat $model 0 1 4 | Out-Null } catch {}
  $dl=(Get-Date).AddMinutes(10)
  do { Start-Sleep 3; try { $st=((Invoke-RestMethod "$swap/running" -TimeoutSec 5).running | ? { $_.model -eq $model }).state } catch { $st=$null } }
  while ($st -ne "ready" -and (Get-Date) -lt $dl)
}
function Hash($s) { $md5=[Security.Cryptography.MD5]::Create(); ([BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($s)))).Replace("-","").Substring(0,12) }

$results = @()
foreach ($model in "qwen3.8-27b","qwen3.8-27b-ngram") {
  Write-Host "`n==== $model ===="
  WaitReady $model
  # temp 0 - must be deterministic & identical across models
  $j = Chat $model 0 $null 1500
  $c = $j.choices[0].message.content
  $results += [pscustomobject]@{ model=$model; temp=0; run=1; tokens=$j.timings.predicted_n; words=($c -split '\s+').Count; finish=$j.choices[0].finish_reason; hash=(Hash $c) }
  Write-Host ("  temp0     tok={0,-4} words={1,-4} finish={2,-6} hash={3}" -f $j.timings.predicted_n, ($c -split '\s+').Count, $j.choices[0].finish_reason, (Hash $c))
  # temp 0.7 x3 fixed seeds - length spread
  foreach ($s in 1,2,3) {
    $j = Chat $model 0.7 $s 1500
    $c = $j.choices[0].message.content
    $results += [pscustomobject]@{ model=$model; temp=0.7; run=$s; tokens=$j.timings.predicted_n; words=($c -split '\s+').Count; finish=$j.choices[0].finish_reason; hash=(Hash $c) }
    Write-Host ("  t0.7 s{0}    tok={1,-4} words={2,-4} finish={3}" -f $s, $j.timings.predicted_n, ($c -split '\s+').Count, $j.choices[0].finish_reason)
  }
}
$results | Export-Csv (Join-Path $outDir "length-parity-$stamp.csv") -NoTypeInformation
"`n=== temp-0 parity (hashes MUST match if spec is correct) ==="
$results | Where-Object temp -eq 0 | Format-Table model,tokens,words,finish,hash -Auto
"=== temp-0.7 length by model ==="
$results | Where-Object temp -eq 0.7 | Group-Object model | ForEach-Object {
  $t = $_.Group.tokens; "{0}: tokens {1}  (mean {2:N0})" -f $_.Name, ($t -join ','), ($t | Measure-Object -Average).Average
}
try { Chat "qwen3.8-27b-ngram" 0 1 4 | Out-Null } catch {}
