# Safety rules (Zeus)

The production llama-swap service is the daily driver. Suffix experiments must not take it down or silently change default models.

## Do

- Add **new llama-swap ids** (aliases) that copy flags 1:1 and add spec types.
- Point experiment ids at a **side-by-side** `llama-server.exe` if we build a custom SYCL binary. Never overwrite `C:\Users\jstaples2\AI\Runtimes\llama.cpp\b10488\`.
- Unload backends when done (`POST /api/models/unload` or swap back to the daily id).
- Keep exclusive routing (one model in VRAM). Dual concurrent loads previously exhausted host RAM.

## Do not

- Edit the live `qwen3.8-27b` / `qwen3.8-27b-q6` / `gpt-oss-120b` command blocks in `C:\llama-swap\config.windows.yaml` except to **add** a sibling id.
- Use `--split-mode row` (segfaults on this SYCL + Arc combo).
- Combine 262144 context with MTP on Qwen3.8 (device-lost).
- Load gpt-oss-120b “just to try ngram” as the first experiment; use gpt-oss-20b on one card instead.
- Leave an experiment model loaded if production traffic needs the default.

## Live paths (host-local, not in git)

| Item | Path |
|---|---|
| llama-swap config | `C:\llama-swap\config.windows.yaml` |
| llama-swap binary | `C:\llama-swap\llama-swap.exe` |
| Production llama-server | `C:\Users\jstaples2\AI\Runtimes\llama.cpp\b10488\llama-server.exe` |
| Public endpoint | `http://100.89.126.50:8080/v1` |
| Qwen3.8 Q8 | `C:\models\bartowski\Qwen3.8-27B-GGUF\Qwen3.8-27B-Q8_0.gguf` |
| gpt-oss-20b | `D:\AI\LLM\Models\unsloth\gpt-oss-20b-GGUF\gpt-oss-20b-Q8_0.gguf` |

Backup the llama-swap yaml before any edit:

```powershell
Copy-Item C:\llama-swap\config.windows.yaml C:\llama-swap\config.windows.backup-suffix-$(Get-Date -Format yyyyMMdd-HHmm).yaml
```
