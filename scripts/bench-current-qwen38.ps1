# Compare speculative drafters on the current production binary without changing
# llama-swap's configuration. Restores the model that was loaded before the run.
param(
    [string]$Executable = 'C:\Users\jstaples2\AI\Runtimes\llama.cpp\b11190-f16\llama-server.exe',
    [string]$BuildLabel = 'b11190-f16',
    [switch]$IncludeSuffix,
    [switch]$OnlySuffix,
    [int]$SuffixMinMatchLen = 5,
    [int]$SuffixNMax = 32
)
$ErrorActionPreference = 'Stop'
$swap = 'http://100.89.126.50:8080'
$port = 9099
$exe = $Executable
$model = 'C:\models\bartowski\Qwen3.8-27B-GGUF\Qwen3.8-27B-Q8_0.gguf'
$mmproj = 'C:\models\bartowski\Qwen3.8-27B-GGUF\mmproj-F16.gguf'
$outDir = Join-Path $env:TEMP 'suffix-decoding'
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outFile = Join-Path $outDir "qwen38-$BuildLabel-spec-$stamp.jsonl"
$prior = $null
$unloaded = $false

$env:Path = (Split-Path $exe -Parent) + ';C:\Program Files (x86)\Intel\oneAPI\ocloc\latest\bin;' + $env:Path
$env:UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS = '1'
$env:ZES_ENABLE_SYSMAN = '1'
$env:GGML_SYCL_ENABLE_VMM = '0'
$env:ONEAPI_DEVICE_SELECTOR = 'level_zero:*'

function Running {
    @( (Invoke-RestMethod "$swap/running" -NoProxy -TimeoutSec 10).running )
}

function Chat([string]$prompt, [int]$maxTokens) {
    $body = @{ messages = @(@{ role = 'user'; content = $prompt }); max_tokens = $maxTokens;
               temperature = 0; seed = 42; chat_template_kwargs = @{ enable_thinking = $false } } |
            ConvertTo-Json -Depth 6
    Invoke-RestMethod "http://127.0.0.1:$port/v1/chat/completions" -Method Post -Body $body `
        -ContentType 'application/json' -TimeoutSec 300
}

$quote = '"'
$prompts = @(
    @{name='json_1'; n=80; text="Return ONLY valid JSON, no markdown: {${quote}ok${quote}: true, ${quote}items${quote}: [1, 2, 3], ${quote}status${quote}: ${quote}done${quote}}"},
    @{name='json_2'; n=80; text="Return ONLY valid JSON, no markdown: {${quote}ok${quote}: true, ${quote}items${quote}: [1, 2, 3], ${quote}status${quote}: ${quote}done${quote}}"},
    @{name='json_3v'; n=80; text="Return ONLY valid JSON, no markdown: {${quote}ok${quote}: true, ${quote}items${quote}: [4, 5, 6], ${quote}status${quote}: ${quote}done${quote}}"},
    @{name='code_1'; n=180; text='Write a complete Python function that merges two sorted lists into one sorted list without using heapq or sort. Include a brief comment. No extra prose.'},
    @{name='code_2'; n=180; text='Write a complete Python function that merges two sorted lists into one sorted list without using heapq or sort. Include a brief comment. No extra prose.'},
    @{name='code_3'; n=180; text='Write a complete Python function that merges two sorted lists into one sorted list without using heapq or sort. Include a brief comment. No extra prose.'},
    @{name='refactor'; n=220; text='Refactor that merge_sorted_lists function so a beginner can understand it. More comments, same behavior. Return only the code.'}
)
$configs = @(
    @{label='mtp'; spec=@('--spec-type','draft-mtp','--spec-draft-n-max','3')},
    @{label='ngram+mtp'; spec=@('--spec-type','ngram-mod,draft-mtp','--spec-draft-n-max','3')}
)
if ($IncludeSuffix) {
    $suffixConfig = @{label="suffix+mtp-m$SuffixMinMatchLen-n$SuffixNMax"; spec=@('--spec-type','suffix,draft-mtp','--spec-draft-n-max','3','--spec-suffix-min-match-len',"$SuffixMinMatchLen",'--spec-suffix-n-max',"$SuffixNMax")}
    if ($OnlySuffix) { $configs = @($suffixConfig) }
    else { $configs += $suffixConfig }
}
$baseArgs = @('-m', $model, '--mmproj', $mmproj, '--image-min-tokens', '1024',
    '-ngl','99','-np','1','-c','131072','-t','8','--load-mode','dio',
    '-ctk','q4_0','-ctv','q4_0','-b','2048','-ub','512','-fa','on',
    '--jinja','--reasoning','off','--metrics','--host','127.0.0.1','--port',"$port")

try {
    $running = @(Running)
    if ($running.Count -gt 1) { throw "Multiple models loaded: $($running.model -join ', ')" }
    if ($running.Count -eq 1) {
        $prior = $running[0].model
        $proxy = $running[0].proxy
        $slots = @(Invoke-RestMethod "$proxy/slots" -TimeoutSec 10)
        if (@($slots | Where-Object is_processing).Count -gt 0) { throw "$prior is processing a request; aborting" }
        Write-Host "Unloading idle $prior; will restore it at end."
        Invoke-WebRequest "$swap/api/models/unload" -NoProxy -Method Post -TimeoutSec 30 | Out-Null
        $unloaded = $true
        $deadline = (Get-Date).AddMinutes(3)
        do {
            Start-Sleep -Seconds 3
            $running = @(Running)
            if ($running.Count -eq 1 -and $running[0].model -eq $prior -and $running[0].state -eq 'ready') {
                try { $activeSlots = @(Invoke-RestMethod "$($running[0].proxy)/slots" -TimeoutSec 5) }
                catch { $activeSlots = @() }
                if (@($activeSlots | Where-Object is_processing).Count -gt 0) {
                    throw "$prior received a new request during unload; aborting benchmark"
                }
            }
        }
        while ($running.Count -gt 0 -and (Get-Date) -lt $deadline)
        if ($running.Count -gt 0) { throw 'Timed out unloading prior model' }
    }

    foreach ($cfg in $configs) {
        $label = $cfg.label
        $log = Join-Path $outDir "qwen38-$BuildLabel-$($label.Replace('+','-'))-$stamp.log"
        $proc = $null
        Write-Host "Starting $label on port $port"
        try {
            $proc = Start-Process -FilePath $exe -ArgumentList ($baseArgs + $cfg.spec) `
                -WorkingDirectory (Split-Path $exe -Parent) -WindowStyle Hidden -PassThru `
                -RedirectStandardError $log -RedirectStandardOutput "$log.out"
            $deadline = (Get-Date).AddMinutes(10)
            $healthy = $false
            do {
                Start-Sleep -Seconds 3
                try { $healthy = (Invoke-WebRequest "http://127.0.0.1:$port/health" -TimeoutSec 5).StatusCode -eq 200 }
                catch { $healthy = $false }
            } while (-not $healthy -and -not $proc.HasExited -and (Get-Date) -lt $deadline)
            if (-not $healthy) { throw "$label server did not become healthy; see $log" }
            Chat 'Reply exactly ping.' 8 | Out-Null
            foreach ($pr in $prompts) {
                $watch = [System.Diagnostics.Stopwatch]::StartNew()
                $response = Chat $pr.text $pr.n
                $watch.Stop()
                $t = $response.timings
                $row = [ordered]@{
                    ts=(Get-Date).ToString('o'); build=$BuildLabel; config=$label; prompt=$pr.name;
                    elapsed_s=[math]::Round($watch.Elapsed.TotalSeconds,3);
                    prompt_n=$t.prompt_n; prompt_tps=$t.prompt_per_second;
                    predicted_n=$t.predicted_n; predicted_tps=$t.predicted_per_second;
                    draft_n=$t.draft_n; draft_accepted=$t.draft_n_accepted;
                    finish_reason=$response.choices[0].finish_reason
                }
                $row | ConvertTo-Json -Compress | Add-Content $outFile
                Write-Host ("  {0,-8} {1,6:N1} t/s  {2,4} tokens  accepted {3}/{4}  wall {5:N2}s" -f `
                    $pr.name,$row.predicted_tps,$row.predicted_n,$row.draft_accepted,$row.draft_n,$row.elapsed_s)
            }
        } finally {
            if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
            Start-Sleep -Seconds 8
        }
    }
} finally {
    if ($unloaded -and $prior) {
        Write-Host "Checking restore state for $prior"
        try {
            $running = @(Running)
            if (@($running | Where-Object { $_.model -eq $prior -and $_.state -eq 'ready' }).Count -ne 1) {
                $body = @{ model=$prior; messages=@(@{role='user';content='Reply exactly ping.'}); max_tokens=8 } | ConvertTo-Json -Depth 5
                Invoke-RestMethod "$swap/v1/chat/completions" -NoProxy -Method Post -Body $body `
                    -ContentType 'application/json' -TimeoutSec 600 | Out-Null
                $running = @(Running)
            }
            if (@($running | Where-Object { $_.model -eq $prior -and $_.state -eq 'ready' }).Count -ne 1) {
                Write-Warning "Restore state uncertain: $($running | ConvertTo-Json -Compress)"
            } else { Write-Host "Restored $prior" }
        } catch { Write-Warning "RESTORE FAILED: $_" }
    }
    Write-Host "Results: $outFile"
}
