# Suffix decoding on llama.cpp (Intel Arc)

Bring [SuffixDecoding](https://arxiv.org/abs/2411.04975) (NeurIPS 2025 Spotlight) to **mainline llama.cpp**, then measure it on dual **Intel Arc Pro B70** (Windows SYCL).

vLLM already ships this via [Arctic Inference](https://github.com/snowflakedb/ArcticInference) (`speculative_config.method = "suffix"`). [ik_llama.cpp#1646](https://github.com/ikawrakow/ik_llama.cpp/pull/1646) has a CPU suffix tree. Mainline llama.cpp does not. That gap is the work.

This repo is the **lab notebook + experiment harness**. The C++ port will live on a branch of `ggml-org/llama.cpp` and, if it works, go upstream. Do not treat this tree as a llama.cpp fork.

## Hardware under test

| | |
|---|---|
| Host | Zeus (Windows 11) |
| GPUs | 2× Intel Arc Pro B70 (32 GB) |
| Engine | llama.cpp SYCL **b10488** (`llama-server`) |
| Router | llama-swap, exclusive one-model-at-a-time |
| Primary target | Qwen3.8-27B Q8_0, both cards, 131k, MTP n-max 3 |
| Sandbox | gpt-oss-20b Q8_0 (~12.1 GB), one card |

Production defaults stay on stock b10488. Experiment aliases only.

## What SuffixDecoding is

Model-free speculative decoding: a **CPU suffix tree** over the prompt, the current generation, and (optionally) prior outputs proposes draft tokens. The target model verifies them in one forward pass. Output distribution is unchanged.

It pays on **repetitive / agentic** work (tool JSON, code edit, self-refine). It does not pay on open chat. Paper 5.3× is AgenticSQL vs vanilla on H100, not a promise for Arc.

## Status

Parked notes: [`docs/PLAN.md`](docs/PLAN.md). First A/B: [`docs/RESULTS-2026-08-26.md`](docs/RESULTS-2026-08-26.md).

1. ~~This repo.~~
2. ~~Stock-binary A/B: `ngram-mod,draft-mtp` vs MTP-only on Qwen3.8.~~ Warm-repeat **+42%** (43 → 62 t/s); 3-cycle code **+45%**; JSON too short for extra lift; **refactor has no lift**. Alias `qwen3.8-27b-ngram` exists; **not** preload.
3. Custom SYCL llama.cpp build. **Blocked:** Intel oneAPI (`icx`) is not installed. Winget has `Intel.OneAPI.BaseToolkit`. Gate: custom binary must match b10488 Qwen3.8 MTP t/s before we bench suffix.
4. ~~Port `common/suffix-tree.{h,cpp}` onto b10488 speculative API.~~ Local branch `suffix-decoding` in `C:\Users\jstaples2\Projects\llama.cpp-suffix` (`--spec-type suffix,draft-mtp`). Not compiled yet.
5. gpt-oss-20b one-card sandbox if real agent traces still want a better-than-ngram corpus tree.

See [`docs/SAFETY.md`](docs/SAFETY.md) before touching llama-swap or the cards.

## Layout

```
docs/          PLAN.md, SAFETY.md, hardware notes
configs/       llama-swap experiment snippets (not the live service file)
benches/       prompts and how to measure t/s + draft accept
scripts/       local helpers (Windows / PowerShell)
results/       gitignored run logs
notes/         paper and implementation links
```

## Non-goals

- Running ik_llama.cpp as the Zeus server
- vLLM XPU on this Windows host
- EAGLE-3 on gpt-oss before model-free spec is measured
- Changing live `qwen3.8-27b` flags

## License

MIT. Suffix tree code ported from ik_llama.cpp remains MIT (ggml / ikawrakow lineage). Cite the paper if you publish numbers:

Oliaro, Jia, Campos, Qiao. *SuffixDecoding: Extreme Speculative Decoding for Emerging AI Applications*. arXiv:2411.04975.
