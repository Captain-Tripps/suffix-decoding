# Stress-test the warm-repeat lift on JSON + refactor + 3-cycle code.
$ErrorActionPreference = "Stop"
$base = "http://100.89.126.50:8080"
$outDir = Join-Path (Split-Path $PSScriptRoot -Parent) "results"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$outFile = Join-Path $outDir ("qwen38-agent-loop-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".jsonl")

$prompts = @(
  @{ name = "json_1"; n = 80; text = "Return ONLY valid JSON, no markdown: {`"ok`": true, `"items`": [1, 2, 3], `"status`": `"done`"}" },
  @{ name = "json_2"; n = 80; text = "Return ONLY valid JSON, no markdown: {`"ok`": true, `"items`": [1, 2, 3], `"status`": `"done`"}" },
  @{ name = "json_3_variant"; n = 80; text = "Return ONLY valid JSON, no markdown: {`"ok`": true, `"items`": [4, 5, 6], `"status`": `"done`"}" },
  @{ name = "code_1"; n = 180; text = "Write a complete Python function that merges two sorted lists into one sorted list without using heapq or sort. Include a brief comment. No extra prose." },
  @{ name = "code_2"; n = 180; text = "Write a complete Python function that merges two sorted lists into one sorted list without using heapq or sort. Include a brief comment. No extra prose." },
  @{ name = "code_3"; n = 180; text = "Write a complete Python function that merges two sorted lists into one sorted list without using heapq or sort. Include a brief comment. No extra prose." },
  @{ name = "refactor"; n = 220; text = "Sounds good. Refactor that merge_sorted_lists function so a beginner can understand it. More comments, same behavior. Return only the code." }
)
$models = @("qwen3.8-27b", "qwen3.8-27b-ngram")

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

foreach ($model in $models) {
  Write-Host "==== $model ===="
  $null = Invoke-Chat $model "Reply with exactly: ping." 8
  foreach ($p in $prompts) {
    $j = Invoke-Chat $model $p.text $p.n
    $content = ""
    if ($j.choices[0].message.content) {
      $content = ($j.choices[0].message.content -replace "\s+", " ")
      if ($content.Length -gt 72) { $content = $content.Substring(0, 72) }
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
    Write-Host ("{0} {1}: tg={2:N1} n={3} draft={4}" -f $model, $p.name, $row.predicted_tps, $row.predicted_n, $acc)
  }
}
Write-Host "wrote $outFile"
