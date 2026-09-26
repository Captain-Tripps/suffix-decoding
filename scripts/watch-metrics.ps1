# Poll llama-swap's proxied llama-server metrics for qwen3.8-27b-ngram during the
# Bespoke canary run. Logs cumulative counters + per-interval deltas so we can see
# decode t/s and draft acceptance evolve across the pipeline's passes.
param(
  [int]$IntervalSec = 20,
  [int]$MaxMinutes  = 75
)
$ErrorActionPreference = "Continue"
$url = "http://100.89.126.50:8080/upstream/qwen3.8-27b-ngram/metrics"
$out = Join-Path (Split-Path $PSScriptRoot -Parent) ("results/canary-metrics-" + (Get-Date -Format yyyyMMdd-HHmmss) + ".csv")
"ts,pred_total,pred_sec_total,draft_total,accept_total,d_pred,d_sec,d_draft,d_accept,interval_tps,interval_accept_pct" | Out-File $out -Encoding utf8

function Grab {
  try { $m = Invoke-RestMethod $url -TimeoutSec 8 } catch { return $null }
  $h = @{}
  foreach ($ln in ($m -split "`n")) {
    if ($ln -match '^llamacpp:(\S+)\s+([\d\.eE+-]+)') { $h[$Matches[1]] = [double]$Matches[2] }
  }
  [pscustomobject]@{
    pred   = $h['tokens_predicted_total']
    sec    = $h['tokens_predicted_seconds_total']
    draft  = $h['spec_decode_num_draft_tokens_total']
    accept = $h['spec_decode_num_accepted_tokens_total']
  }
}

$prev = Grab
$deadline = (Get-Date).AddMinutes($MaxMinutes)
Write-Host "watching $url  ->  $out"
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds $IntervalSec
  $cur = Grab
  if ($null -eq $cur -or $null -eq $cur.pred) { continue }
  $dp = $cur.pred   - $prev.pred
  $ds = $cur.sec    - $prev.sec
  $dd = $cur.draft  - $prev.draft
  $da = $cur.accept - $prev.accept
  $tps = if ($ds -gt 0) { [math]::Round($dp / $ds, 1) } else { 0 }
  $acc = if ($dd -gt 0) { [math]::Round(100.0 * $da / $dd, 1) } else { 0 }
  $ts = (Get-Date).ToString("s")
  "$ts,$($cur.pred),$($cur.sec),$($cur.draft),$($cur.accept),$dp,$([math]::Round($ds,2)),$dd,$da,$tps,$acc" | Add-Content $out
  if ($dp -gt 0) { Write-Host ("{0}  +{1,5} tok  {2,6:N1} t/s  draft {3}/{4} ({5}%)" -f $ts,$dp,$tps,$da,$dd,$acc) }
  $prev = $cur
}
Write-Host "done -> $out"
