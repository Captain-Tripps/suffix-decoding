# Hardware and baselines

## Zeus

- Windows 11, dual Intel Arc Pro B70 (Battlemage / Xe2), 32 GB GDDR6 each
- llama.cpp SYCL official zip **b10488** (includes the b10456 Q4_0→f32 copy-kernel fix)
- llama-swap exclusive group; `GGML_SYCL_ENABLE_VMM=0`, `UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS=1`

## Qwen3.8-27B Q8_0 (production default)

Tuned 2026-08-18 on b10488, both cards, 131072 ctx, Q4 KV, `--spec-type draft-mtp --spec-draft-n-max 3`:

| Prompt class | n-max 0 | n-max 2 | n-max 3 | n-max 4 |
|---|---|---|---|---|
| easy_count | ~15 t/s | ~36 t/s | ~45 t/s | ~52 t/s |
| hard_code | ~15 t/s | ~36 t/s | ~44 t/s | ~48 t/s |
| hard_reason | ~15 t/s | ~32 t/s | ~34 t/s | ~32 t/s (accept ~61%) |

Source JSONL (host): `C:\Users\jstaples2\AI\Runtimes\llama.cpp\test-logs\qwen38-tune-mtp.jsonl`

n-max 3 is the balanced production pick. Suffix/ngram A/B must beat **n-max 3**, not n-max 0.

## gpt-oss-20b sandbox

- `D:\AI\LLM\Models\unsloth\gpt-oss-20b-GGUF\gpt-oss-20b-Q8_0.gguf` (12.1 GB, 2026-08-03)
- Not in llama-swap yet
- Fits one B70 (`ONEAPI_DEVICE_SELECTOR=level_zero:0`, `-ngl 99`)
- Start 32k or 65k context; raise after a clean load
- No native MTP in this GGUF; model-free spec only for v1

## Known traps

- Older SYCL: extra draft tokens can be **net-negative** (Ornith MTP n-max 0 beat n-max 2–4). Qwen3.8 on b10488 flipped that for MTP; do not assume ngram/suffix will.
- DeepSeek-70B on this box: MTP/DFlash/ngram all net-negative.
- llama.cpp PR #21845 (SYCL multi-column MMVQ) claimed large MTP speedups on B70; **unconfirmed** whether b10488 includes it.
- Concurrent two-model loads on the two cards previously dumped host RAM. Stay exclusive.
