# Suffix decoding on llama.cpp (Intel Arc)

Bring [SuffixDecoding](https://arxiv.org/abs/2411.04975) (NeurIPS 2025 Spotlight) to **mainline llama.cpp**, then measure it on dual **Intel Arc Pro B70** (Windows SYCL).

vLLM already ships this via [Arctic Inference](https://github.com/snowflakedb/ArcticInference) (`speculative_config.method = "suffix"`). [ik_llama.cpp#1646](https://github.com/ikawrakow/ik_llama.cpp/pull/1646) has a CPU suffix tree. Mainline llama.cpp does not. That gap is the work.

This repo is the **lab notebook + experiment harness**. The C++ port will live on a branch of `ggml-org/llama.cpp` and, if it works, go upstream. Do not treat this tree as a llama.cpp fork.

## Hardware under test

| | |
|---|---|
| Host | Zeus (Windows 11) |
| GPUs | 2× Intel Arc Pro B70 (32 GB) |
| Engine | llama.cpp SYCL **b11190-f16** (`llama-server`); isolated suffix build from local `f4f929f` source |
| Router | llama-swap, exclusive one-model-at-a-time |
| Primary target | Qwen3.8-27B Q8_0, both cards, 131k, MTP n-max 3 |
| Sandbox | gpt-oss-20b Q8_0 (~12.1 GB), one card |

Production models use the tuned b11190-f16 runtime. The suffix binary is an isolated experiment; it was not installed as a production runtime.

## What SuffixDecoding is

Model-free speculative decoding: a **CPU suffix tree** over the prompt, the current generation, and (optionally) prior outputs proposes draft tokens. The target model verifies them in one forward pass. Output distribution is unchanged.

It pays on **repetitive / agentic** work (tool JSON, code edit, self-refine). It does not pay on open chat. Paper 5.3× is AgenticSQL vs vanilla on H100, not a promise for Arc.

## Status

**September 26 update:** [`docs/RESULTS-2026-09-25-b11190-qwen38.md`](docs/RESULTS-2026-09-25-b11190-qwen38.md) repeats the Qwen3.8 Q8 A/B on the current b11190-f16 runtime and on a newer, isolated suffix-enabled SYCL build. On the same custom binary, `ngram-mod,draft-mtp` reached **98-103 t/s** on identical code repeats. Default `suffix,draft-mtp` reached **43-55 t/s** on those repeats and slowed short JSON from about **44 to 10-13 t/s**. A 16-token minimum match did not remove the regression; limiting suffix drafts to 8 tokens dropped warm code to about **16 t/s**. Keep suffix out of production. The prompts are short and synthetic; a representative agent trace remains unmeasured. The reproducible local harness is [`scripts/bench-current-qwen38.ps1`](scripts/bench-current-qwen38.ps1).

The steps below record the August work and its then-current state.

Parked notes: [`docs/PLAN.md`](docs/PLAN.md). First A/B: [`docs/RESULTS-2026-08-26.md`](docs/RESULTS-2026-08-26.md).

1. ~~This repo.~~
2. ~~Stock-binary A/B: `ngram-mod,draft-mtp` vs MTP-only on Qwen3.8.~~ Warm-repeat **+42%** (43 → 62 t/s); 3-cycle code **+45%**; JSON too short for extra lift; **refactor has no lift**. Alias `qwen3.8-27b-ngram` exists; **not** preload.
3. ~~Custom SYCL llama.cpp build.~~ **Built 2026-08-26.** oneAPI 2025.1.1 installed (winget `Intel.OneAPI.Toolkit` exited 1 but components are usable); top-level `setvars.bat` dispatcher is broken (`'vars.bat' is not recognized` per component) so `scripts/build-sycl.cmd` calls the component `vars.bat` scripts directly and sets `VS2022INSTALLDIR` for VS 18. Binary at `C:\Users\jstaples2\AI\Runtimes\llama.cpp\suffix-sycl\` (commit `cb9f787`). `--spec-type` exposes `suffix`; flags `--spec-suffix-{n-max,max-depth,min-match-len,corpus}`. Corpus tokenization was wired in a later commit.
4. ~~Port `common/suffix-tree.{h,cpp}` onto b10488 speculative API.~~ Local branch `suffix-decoding` in `C:\Users\jstaples2\Projects\llama.cpp-suffix` (`--spec-type suffix,draft-mtp`). Compiled.
5. ~~Gate test.~~ Failed first on oneAPI 2025.1 (3x slow — B70 arch paths shimmed out), then fixed: oneAPI **2026.0** has the `intel_gpu_bmg_g31` enum; its `winget` install shipped a **0-byte `umf.dll`** that broke the Level Zero adapter, worked around by `scripts/stage-runtime.ps1` (bundles the runtime next to the exe, b10488-style). **Gate PASSED** — custom build 45/44/44/34 vs b10488 44/43/43/32 t/s. See [`docs/RESULTS-2026-08-26-oneapi2026.md`](docs/RESULTS-2026-08-26-oneapi2026.md).
6. ~~Bench `--spec-type suffix`.~~ **Done 2026-08-26** ([`docs/RESULTS-2026-08-26-suffix-bench.md`](docs/RESULTS-2026-08-26-suffix-bench.md)): **ngram-mod+mtp wins** (2.2x on warm code repeats, no regressions). **suffix regresses hard** on non-matching prompts (JSON 43→10 t/s, refactor 38→30) — linear low-confidence drafts waste verify passes; even its best warm case (58 t/s) loses to ngram-mod (96–103). The corpus preload was wired later, but the [cold creative-prose test](docs/RESULTS-2026-08-26-corpus.md) found no gain; an agentic corpus remains untested.
7. gpt-oss-20b one-card sandbox if real agent traces still want a better-than-ngram corpus tree.

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
