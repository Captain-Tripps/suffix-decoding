# Gate test — custom suffix-sycl binary vs stock b10488 (2026-08-26)

**Result: FAILED.** The custom SYCL build decodes ~3x slower than stock b10488.
Not a valid vehicle for suffix benchmarking until the SYCL binary matches b10488.

## Setup

- Binary: `C:\Users\jstaples2\AI\Runtimes\llama.cpp\suffix-sycl\llama-server.exe`
  (commit `cb9f787`, master + suffix port, built with oneAPI DPC++ **2025.1.1**).
- Flags: **identical** to production `qwen3.8-27b` (Q8_0, both cards via `-ngl 99`,
  `-c 131072`, `-ctk/-ctv q4_0`, `-b 2048 -ub 512`, `-fa on`, `--spec-type draft-mtp
  --spec-draft-n-max 3`). Only binary path + port changed. Run standalone on :9099,
  llama-swap unloaded (gpt-oss-120b restored after).
- Bench: `scripts/gate-test.ps1`, temp 0, thinking off.

## Numbers (decode t/s, MTP n-max 3)

| Prompt | b10488 baseline | custom suffix-sycl | ratio |
|---|---|---|---|
| easy_count  | 43.98 | **14.35** | 0.33x |
| hard_code   | 43.41 | **14.10** | 0.32x |
| warm_repeat | 43.26 | **14.09** | 0.33x |
| hard_reason | 32.35 | **10.88** | 0.34x |

Prompt processing was fine / faster on the custom build (easy pp 46.9 vs 30.9,
code pp 67.5 vs 43.9). First warmup task ate 30 s of one-time SYCL kernel JIT.

## Diagnosis

MTP **drafting works** — acceptance 98–100% (`draft = 100/102`), same as b10488.
But decode wall-clock equals the *no-MTP* rate (~14–15 t/s). So each verify step
of N accepted draft tokens costs ~N single-token decodes: the multi-token /
batched GEMV verify path is slow in this build.

Most likely cause: the oneAPI-2025.1 **compile shims**. DPC++ 2025.1 headers lack
the `intel_gpu_bmg_g31` architecture enum (Arc Pro B70), so `scripts/build-sycl.cmd`
+ the 4 uncommitted `ggml-sycl` patches guard every `bmg_g31` reference behind
`GGML_SYCL_HAS_BMG_G31` (== 0 on 2025.1). That **disables the B70's tuned paths**:

- `fattn-onednn.cpp` — B70 excluded from the oneDNN flash-attention path -> generic FA kernel.
- `fattn-vec.hpp` — B70 loses the 256-thread FA-vec workgroup (falls to 128).

The official Intel/ggml SYCL release (b10488) is built with a DPC++ that knows
`bmg_g31`, so it keeps those paths. Secondary suspects: build-flag deltas vs the
official release, or a post-b10488 master SYCL regression.

## Next options

1. **oneAPI 2025.2+ / 2026.0 DPC++** (has `intel_gpu_bmg_g31`), rebuild without the
   shims, re-run the gate. Biggest lever. `winget Intel.OneAPI.Toolkit` exited 1
   once already — may need the offline installer.
2. Isolate: run custom binary **no-spec** vs b10488 no-spec (~15 t/s). If custom
   no-spec also lags, base decode regressed (FA shim). If it matches, only the
   MTP verify path is broken (points at multi-col MMVQ / PR #21845).
3. Park the custom binary; keep suffix work on the stock-binary `ngram-mod` alias
   (already +42% warm) until the toolchain is sorted.

## Housekeeping

Production `gpt-oss-120b` unloaded for the test and restored to `ready` afterward.
No llama-swap config changes. Raw: `results/gate-suffixbin-mtp-20260826-155024.jsonl`,
server log `results/gate-suffixbin-server-20260826-155024.log`.
