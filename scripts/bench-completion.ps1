# A/B llama-swap models via /v1/chat/completions. Records timings JSONL.
# Usage: .\scripts\bench-completion.ps1
$ErrorActionPreference = "Stop"
$base = "http://100.89.126.50:8080"
$outDir = Join-Path (Split-Path $PSScriptRoot -Parent) "results"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outFile = Join-Path $outDir "qwen38-ngram-ab-$stamp.jsonl"

$prompts = @(
  @{ name = "warmup"; text = "Reply with exactly: warmup."; n = 16 },
  @{ name = "easy_count"; text = "Count from 1 to 25, comma-separated, then stop."; n = 80 },
  @{ name = "hard_code"; text = "Write a complete Python function that merges two sorted lists into one sorted list without using heapq or sort. Include a brief comment. No extra prose."; n = 180 },
  @{ name = "warm_repeat"; text = "Same task again, from scratch: write a complete Python function that merges two sorted lists into one sorted list without using heapq or sort. Include a brief comment. No extra prose."; n = 180 },
  @{ name = "hard_reason"; text = "A farmer has 17 sheep. All but 9 die. How many are left? Give a one-sentence explanation then the number."; n = 64 }
)

$models = @("qwen3.8-27b", "qwen3.8-27b-ngram")

function Wait-SwapHealth {
  $deadline = (Get-Date).AddMinutes(12)
  while ((Get-Date) -lt $deadline) {
    try {
      $h = Invoke-WebRequest "$base/health" -UseBasicParsing -TimeoutSec 5
      if ($h.StatusCode -eq 200) { return }
    } catch {}
    Start-Sleep -Seconds 3
  }
  throw "llama-swap health did not return 200"
}

function Wait-ModelReady([string]$model) {
  $deadline = (Get-Date).AddMinutes(12)
  while ((Get-Date) -lt $deadline) {
    try {
      $r = Invoke-RestMethod "$base/running" -TimeoutSec 5
      $hit = @($r.running) | Where-Object { $_.model -eq $model -and $_.state -eq "ready" }
      if ($hit) { return }
    } catch {}
    Start-Sleep -Seconds 3
  }
  throw "model $model did not become ready"
}

function Invoke-Chat([string]$model, [string]$text, [int]$maxTokens) {
  $body = @{
    model = $model
    messages = @(@{ role = "user"; content = $text })
    max_tokens = $maxTokens
    temperature = 0
    chat_template_kwargs = @{ enable_thinking = $false }
  } | ConvertTo-Json -Depth 6
  $r = Invoke-WebRequest "$base/v1/chat/completions" -Method POST -Body $body -ContentType "application/json" -UseBasicParsing -TimeoutSec 300
  return ($r.Content | ConvertFrom-Json)
}

Wait-SwapHealth

foreach ($model in $models) {
  Write-Host "==== $model ===="
  $null = Invoke-Chat $model "Reply with exactly: ping." 8
  Wait-ModelReady $model
  foreach ($p in $prompts) {
    $j = Invoke-Chat $model $p.text $p.n
    $content = ""
    if ($j.choices[0].message.content) {
      $content = ($j.choices[0].message.content -replace "\s+", " ")
      if ($content.Length -gt 80) { $content = $content.Substring(0, 80) }
    }
    $row = [ordered]@{
      ts = (Get-Date).ToString("o")
      model = $model
      prompt = $p.name
      content = $content
      prompt_n = $j.timings.prompt_n
      prompt_tps = $j.timings.prompt_per_second
      predicted_n = $j.timings.predicted_n
      predicted_tps = $j.timings.predicted_per_second
      draft_n = $j.timings.draft_n
      draft_n_accepted = $j.timings.draft_n_accepted
    }
    ($row | ConvertTo-Json -Compress) | Add-Content $outFile
    $acc = if ($row.draft_n) { "{0}/{1}" -f $row.draft_n_accepted, $row.draft_n } else { "-" }
    Write-Host ("{0} {1}: pp={2:N1} tg={3:N1} n={4} draft={5}" -f $model, $p.name, $row.prompt_tps, $row.predicted_tps, $row.predicted_n, $acc)
  }
}

Write-Host "wrote $outFile"
