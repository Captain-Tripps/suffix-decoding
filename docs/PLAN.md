# SuffixDecoding on Zeus (dual Arc Pro B70) — talk-through, no hardware changes

**Status (2026-08-25): parked.** User asked to save and revisit. Do not load models, restart llama-swap, or touch either B70 until a later session.

This is a feasibility briefing, not an implementation ticket.

Paper: [SuffixDecoding: Extreme Speculative Decoding for Emerging AI Applications](https://arxiv.org/html/2411.04975v3) (Oliaro, Jia, Campos, Qiao; NeurIPS 2025 Spotlight). Code: Snowflake [Arctic Inference](https://github.com/snowflakedb/ArcticInference). Production path today: vLLM `speculative_config.method = "suffix"` (+ `pip install arctic-inference`).

## What SuffixDecoding actually is

Speculative decoding is: cheaply guess several next tokens, then have the real model verify them in one forward pass. Accepted tokens are mathematically the same as vanilla decode (output distribution preserved).

Most spec methods pay GPU time to guess (small draft model, EAGLE heads, MTP heads). SuffixDecoding guesses on the CPU from history:

1. Keep two suffix trees of token sequences: a **per-request** tree (this prompt + tokens generated so far) and a **global** tree (prior completed outputs).
2. Match the trailing pattern of the current generation against those trees.
3. Grow a small speculation tree by frequency counts (`COUNT` → estimated accept probability `D(N)`).
4. **Adapt depth**: `MAX_SPEC = α × pattern_match_length`. Long match → speculate aggressively; short match → speculate little or not at all. Typical `α ∈ [1, 4]`.
5. Score candidate trees (`SCORE = Σ D(N)`) and verify only the winner.
6. Optional hybrid: if `SCORE < τ`, fall back to a model-based speculator (paper uses EAGLE-3).

Draft cost in the paper is ~20 µs/token on CPU. Trees live in host RAM, not VRAM. That part is a good fit for Arc: the B70s stay busy only on the target-model verify pass.

Paper numbers (Llama-3.1-8B, batch 1, H100, highly repetitive agent traces):

| Workload | vs vanilla | vs next-best |
|---|---|---|
| AgenticSQL | **5.3×** | 2.8× vs EAGLE-2/3, 1.9× vs Token Recycling |
| SWE-Bench | **2.5×** (7.8 mean accepted tokens/step) | 1.7× vs Prompt Lookup Decoding |
| Spec-Bench (open chat) | suffix **loses** to EAGLE | hybrid suffix+EAGLE-3 wins slightly |

The 5.3× figure is not a general LLM speedup. It is “this JSON-ish multi-agent SQL pipeline repeats keys, booleans, and phrasings, so one verify step can accept dozens of tokens.” End-to-end OpenHands on SWE-Bench Verified was 1.8–4.5× vs vanilla, same 37.2% solve rate.

## What this machine already is

Zeus is Windows 11 + llama.cpp SYCL **b10488**, dual Intel Arc Pro B70, llama-swap exclusive (one model in VRAM). Live production path for the preferred models:

| Model | Config | Spec today | Measured decode (this box) |
|---|---|---|---|
| `qwen3.8-27b` Q8_0, both cards, 131k, Q4 KV | `C:\llama-swap\config.windows.yaml` | `--spec-type draft-mtp --spec-draft-n-max 3` | no MTP ~15 t/s; n=3 ~45 t/s easy/code, ~34 t/s hard; n=4 52 t/s easy but 32 t/s / 61% accept on hard |
| `qwen3.8-27b-q6` UD-Q6_K_XL | same MTP n=3 | same shape | |
| `gpt-oss-120b` UD-Q4_K_XL, both cards, `-ngl auto`, 131k | **no spec** | unknown / not recently spec-swept; already VRAM-tight |
| gpt-oss-20b Q8_0 **on disk, not in llama-swap** | none | `D:\AI\LLM\Models\unsloth\gpt-oss-20b-GGUF\gpt-oss-20b-Q8_0.gguf` (12.1 GB). Fits one B70. |

Known Zeus constraints that dominate any spec discussion:

- One model at a time. Concurrent two-model / two-GPU loading previously exhausted host RAM.
- `--split-mode row` segfaults on this SYCL+Arc combo. Dual-card models use layer split / default split.
- 262k + MTP on Qwen3.8 is device-lost. Keep 131k if spec is on.
- Older SYCL builds: extra draft tokens could be **net-negative** (Ornith MTP n-max 0 beat n-max 2–4). Qwen3.8 on b10488 flipped that: MTP is a real ~3×. Verification cost still matters.
- DeepSeek-70B notes in the same config: MTP/DFlash/ngram all net-negative on that dense 70B. Do not assume “spec always helps.”
- SYCL verify of a long draft is only cheap if the build has decent multi-token GEMV. llama.cpp PR #21845 (multi-column MMVQ on SYCL) reported ~40–90% MTP speedup on Arc Pro B70; b10488 may or may not include that — unconfirmed, do not assume.

## Can we run the paper as published? Honest answer: not on this Windows stack, not as a drop-in

Three real implementations exist. Only one is this machine’s production engine.

### Path A — vLLM + Arctic Inference (the paper’s production code)

```text
pip install vllm arctic-inference
vllm serve <model> --speculative-config '{"method":"suffix","num_speculative_tokens":32}'
```

`num_speculative_tokens` is a **cap**; actual draft length is adaptive.

This is the real SuffixDecoding (suffix trees, frequency scoring, adaptive depth, global cache). vLLM XPU recipes for B70 exist in the wild (Qwen3.8-27B GPTQ-INT4 + **MTP**, Linux Docker). Community reports ~52 t/s MTP2 on one B70, and TP2 MTP on 2× B70.

Blockers on Zeus:

- Production is **Windows llama.cpp SYCL**, not Linux vLLM XPU.
- Arctic suffix is wired in upstream vLLM CUDA/XPU Python; Intel XPU images trail main and have had MTP+concurrency and hybrid-GDN (Qwen3.8) bugs.
- Switching Qwen3.8 off llama.cpp onto vLLM is a stack change, not a flag. Dual-card TP2 on XPU is a second project.

Do not treat this as the first experiment.

### Path B — llama.cpp on this box (what we actually run)

Mainline llama.cpp **does not implement SuffixDecoding**. b10488 speculative types:

- model-based: `draft-mtp`, `draft-eagle3`, `draft-dflash`, `draft-dspark`
- model-free: `ngram-cache`, `ngram-simple`, `ngram-map-k`, `ngram-map-k4v`, `ngram-mod`

N-gram methods are the paper’s cousins (Prompt Lookup Decoding / Token Recycling class): match recent tokens in history, propose the continuation, verify. They do **not** have:

- a real suffix tree with frequency-greedy tree expansion
- `MAX_SPEC = αp` adaptive depth from match length
- a scored global corpus of prior requests (except ngram-mod’s shared hash pool across slots)

They **do** have the property that matters for Arc: **zero extra VRAM, CPU-side drafts**.

llama.cpp can mix types: `--spec-type ngram-mod,draft-mtp` (draftless stage is tried first). That is the paper’s hybrid idea with n-gram standing in for suffix and MTP standing in for EAGLE.

Qwen3.8 already has native MTP heads in the GGUF. gpt-oss-120b as configured has **no** MTP flags; an EAGLE-3 speculator exists (`RedHatAI/gpt-oss-20b-speculator.eagle3`, `lmsys/EAGLE3-gpt-oss-120b-bf16`) but would fight VRAM on a model that already needs both cards with `-ngl auto`.

### Path C — ik_llama.cpp `--spec-type suffix` (the April PR)

This is **not** a ggml-org/llama.cpp PR. It is [ikawrakow/ik_llama.cpp#1646](https://github.com/ikawrakow/ik_llama.cpp/pull/1646) by SamuelOliveirads, merged **18 Apr 2026**. Close issue #1602 was explicitly “add SuffixDecoding (arXiv 2411.04975).”

What the PR actually is (looked at the commits):

- New CPU files `common/suffix-tree.h` + `common/suffix-tree.cpp` (~180 lines): a token trie with `count`, `extend()`, `speculate()` using frequency × `p_min`.
- ~70 lines of wiring in `common/speculative.cpp`: a `common_speculative_state_suffix` that indexes the current request as tokens arrive, then calls `tree.speculate()`.
- Enum + `--spec-type suffix` parsing.
- Second commit: optional `suffix_corpus` (json/bin) and autotune hooks. **This corpus is the paper’s global tree.** Without it, suffix is only the per-request tree.

Author’s own numbers (GLM 4.5 Air, `--spec-autotune`, not Arc): ngram-mod often matched or beat suffix on code/extract/story. Suffix **won** on a follow-up refactor **when a corpus of the previous answer was preloaded** (71 t/s vs 65 t/s ngram-mod). Author: “I haven’t tested it with a lot of context or on an agent.”

Later ik_llama docs use:

```text
--spec-type "suffix:n_max=16,n_min=2,suffix_min_match_len=5,suffix_max_depth=64,suffix_corpus=/path/corpus.json"
```

and two-stage `suffix` then `mtp`.

## Branching llama.cpp ourselves

Yes — that is the right way to get real suffix trees on Zeus. Do **not** replace the production server with ik_llama.

### Why not just run ik_llama.cpp SYCL

- Fork last fully synced with llama.cpp in **August 2024**. Two years of SYCL, GDN/Qwen3.8, MTP, the b10456 Q4 copy-kernel, and Windows prebuilts are missing.
- Qwen3.8-27B hybrid GDN is a current-mainline feature. ik_llama has its own fused delta-net, not the same as b10488.
- Zeus currently uses official **win-sycl-x64 zips** (`b10488`). Switching the live llama-swap binary to a 2024-era fork is a regression, not an experiment.
- ik_llama’s docs say SYCL “refer to llama.cpp” — it is not a maintained Arc Pro B70 Windows path.

### What “our own llama.cpp branch” actually means

The suffix drafter is **backend-agnostic CPU code**. Verification is the existing batched decode path (SYCL already does that for MTP/ngram). So the work is:

1. Clone `ggml-org/llama.cpp` at or near b10488 (or current master if we are willing to re-tune).
2. Port `suffix-tree.{h,cpp}` into `common/` as a sibling of `ngram-mod`.
3. Wire a `COMMON_SPECULATIVE_TYPE_SUFFIX` into **today’s** speculative API (comma-separated `--spec-type`, two-stage with `draft-mtp`). The ik_llama PR will not cherry-pick cleanly; the enum/init/draft callbacks have moved.
4. Keep linear drafts first (same as ngram). Do not start with the paper’s tree-verify kernel.
5. Add `suffix_corpus` load/save so agent loops can pre-warm from prior tool JSON / code.
6. Windows SYCL build with oneAPI (`examples/sycl/win-build-sycl.bat`, `icx`/`icpx`, `GGML_SYCL=ON`, `GGML_SYCL_F16=ON`, Release **with NDEBUG**). Side-install next to `b10488`, do not overwrite it.
7. New llama-swap alias pointing at the custom `llama-server.exe`. Live `qwen3.8-27b` stays on stock b10488 until the alias wins.

Effort: a few days for a working linear suffix + corpus on SYCL, not a research month — **if** the Windows oneAPI build environment is already healthy. The risky part is the SYCL build, not the trie. Zeus has never shipped a homegrown SYCL binary (only official zips). First milestone is “custom b10488-equivalent SYCL server boots Qwen3.8 at current t/s,” then add suffix.

### What we would not get from a first port

- Paper’s greedy **tree** of candidates (JSON true/false branches). llama.cpp verifies a linear draft. Paper’s SWE-Bench linear ≈ tree, so this is acceptable v1.
- Arctic’s global LRU of 10k requests. v1 = per-request tree + one `--suffix-corpus` file we maintain.
- vLLM batch-level speculation control. Irrelevant at `-np 1`.

### Safer first proof than a custom build

Before compiling anything: a stock-b10488 llama-swap alias with `--spec-type ngram-mod,draft-mtp` on Qwen3.8. If ngram-mod does nothing on our agent traces, a prettier suffix tree will not either. If ngram-mod pops on warm repeats, then the branch is justified.

## Smaller GPT-OSS (20B) as a suffix sandbox

OpenAI shipped two sizes: **gpt-oss-20b** (21B total / ~3.6B active MoE) and **gpt-oss-120b**. There is no 7B/8B official gpt-oss.

llama.cpp memory guide (MXFP4):

| Model | Weights | Total @ 8k | Total @ 32k | Total @ 131k |
|---|---|---|---|---|
| gpt-oss-20b | 12.0 GB | **14.9 GB** | **15.5 GB** | **17.9 GB** |
| gpt-oss-120b (what Zeus already has) | 61 GB | 64 GB | 64.9 GB | 68.5 GB |

A single Arc Pro B70 is 32 GB. **20B fits entirely on one card** with 131k context and ~14 GB free. That leftover is enough for:

- long Q4/Q8 KV without hugging the ceiling that made 120B need `-ngl auto` and both cards
- optional EAGLE-3 draft (`RedHatAI/gpt-oss-20b-speculator.eagle3`, ~1.83 GB / 0.9B) — **but** llama.cpp #18039 notes gpt-oss EAGLE-3 has a **MoE performance issue**; on DGX Spark, EAGLE-3 was 0.89–1.06× vs baseline (sometimes slower). Do not count on EAGLE-3 as the win.
- model-free suffix/ngram with cheap verify, because 3.6B active should decode fast (OpenVINO already advertises gpt-oss-20b-int4 on a B70)

Why 20B is a better **suffix experiment vehicle** than 120B:

- No dual-card layer-split, no `-ngl auto` VRAM-fit abort, no 120B WDDM incident surface.
- Can pin `ONEAPI_DEVICE_SELECTOR=level_zero:0` and leave GPU 1 idle (or keep Qwen3.8 experiments off the other card only if we ever violate exclusive llama-swap — we should not).
- Faster baseline → easier to see whether suffix drafts help or hurt.
- Intel published an OpenVINO gpt-oss-20b-int4 B70 recipe; SYCL GGUF should be even more native to this box.

Why 20B is a worse **daily driver** than Qwen3.8-27B:

- Quality drop vs 120B is real. vs Qwen3.8-27B Q8 for coding agents, 20B is the weaker model.
- Qwen3.8 already has working MTP (~3× on this box). gpt-oss-20b has no native MTP heads in the GGUF; suffix/ngram/EAGLE are the only spec knobs.
- Agent Studio default should stay Qwen3.8 until 20B + suffix actually beats it on the tasks we care about.

**Already on this machine (no download):**

`D:\AI\LLM\Models\unsloth\gpt-oss-20b-GGUF\gpt-oss-20b-Q8_0.gguf` — **12.1 GB**, dated 2026-08-03. Not wired into `C:\llama-swap\config.windows.yaml` (no `gpt-oss-20b` id). Size matches the llama.cpp 20B MXFP4-class footprint (~12 GB weights → ~15–18 GB resident at 8k–131k). One B70 (32 GB) has comfortable headroom; do not layer-split it across both cards.

When we touch hardware: new llama-swap id, `ONEAPI_DEVICE_SELECTOR=level_zero:0`, `-ngl 99`, start at 32k or 65k ctx (raise after a clean load), ngram-mod first on stock b10488; suffix after the custom build exists. Leave `gpt-oss-120b` as the quality GPT-OSS option.

## Revised recommendation order

1. **Talk-only until an idle window.** No llama-swap edits, no builds, no downloads yet.
2. **Stock-binary A/B on Qwen3.8:** new alias `ngram-mod,draft-mtp` vs current MTP-only. If warm agent traces do not move, stop.
3. **If ngram helps, or we want the paper’s corpus tree anyway:** custom SYCL llama.cpp branch with ported `suffix-tree` + `suffix_corpus`. Side-by-side binary, new alias.
4. **gpt-oss-20b** as the low-risk suffix sandbox (one card, lots of VRAM headroom) **in parallel with (3)**, not as a replacement for Qwen3.8. Skip gpt-oss-120b for suffix until 20B proves the mechanism.
5. **Do not** run ik_llama as the Zeus server. **Do not** vLLM-XPU Windows. **Do not** EAGLE-3 on gpt-oss until suffix/ngram is measured.

## What is actually worth doing on these two B70s

### Recommendation order (when we decide to touch anything)

1. **Do not rewrite Arctic in C++.** Weeks of work, worse than using existing ngram or ik_llama.

2. **First cheap experiment (Qwen3.8, existing binary):** a **new llama-swap alias**, not a mutation of `qwen3.8-27b`.
   - Keep MTP n-max 3 (already the tuned default).
   - Add a model-free stage: `--spec-type ngram-mod,draft-mtp` (and a second alias with `ngram-simple`).
   - Bench on (a) repetitive agent/code/JSON, (b) hard reasoning, (c) warm repeat of the same task (the paper’s agentic loop).
   - Success = higher t/s **and** equal quality vs current MTP-only. Failure = slower on hard prompts because rejected long drafts waste SYCL verify.

3. **gpt-oss-120b:** model-free only. Try `ngram-mod` (or ngram-simple) as a **new alias**. Do not add EAGLE-3 until we know leftover VRAM after `-ngl auto` at 131k. Do not enable MTP flags that are not in this GGUF.

4. **True suffix trees** only if step 2 shows n-gram acceptance is high on our real agent traces (OpenClaw / Agent Studio / code edit). Then either:
   - wait for mainline llama.cpp to grow a suffix type, or
   - vendor the Arctic CPU cache as a llama.cpp spec implementation (non-trivial), or
   - evaluate Linux vLLM XPU in a throwaway VM — not on the live Windows service.

5. **Do not** expect paper 5.3× on Zeus. Realistic envelope if the workload is actually repetitive:
   - Qwen3.8 already took the easy 15 → ~45 t/s via MTP. Suffix/ngram can add on **warm agent loops** (repeat JSON, repeat tool schemas, self-refine). Strix Halo Qwen3.8 reports ngram-mod + MTP jumping ~60 t/s cold to ~150 t/s on warm repeats. That is the shape to hunt, not a 5× on first-token chat.
   - gpt-oss has more headroom because it currently has **zero** spec. If n-gram drafts accept well, 1.2–2× on agentic decode is plausible; if not, it will look like DeepSeek-70B (net-negative).

### Why Qwen3.8 is the better first target than gpt-oss

- Already stable on both cards with MTP; we have a baseline JSONL (`AI/Runtimes/llama.cpp/test-logs/qwen38-tune-mtp.jsonl`).
- Hybrid GDN architecture: decode is relatively cheap per token, so extra accepted tokens convert to wall-clock more cleanly than a dense 70B.
- Agent Studio default model.
- gpt-oss is VRAM-tight, dual-card, historically involved in the WDDM/iGPU RAM-spike incident. Higher blast radius.

### Why the paper’s tree speculation may not fully land even if we ported it

Paper verifies a **tree** of candidates (branch at JSON true/false, etc.). llama.cpp n-gram/MTP paths are mostly **linear** drafts. Tree verify is a bigger kernel/batching change than “enable suffix.” Arctic+vLLM has that; llama.cpp would not, first pass. Linear suffix still helped in the paper (SWE-Bench linear ≈ tree), so linear n-gram is not a waste.

## Explicit non-goals until we agree otherwise

- Do not stop/restart llama-swap or load either card.
- Do not swap the live `qwen3.8-27b` flags.
- Do not install vLLM XPU on this Windows host as a side stack without a separate plan.
- Do not build ik_llama SYCL “just to get `--spec-type suffix`” as step 1.

## Open questions (need you, not the hardware)

1. **Workload:** Agent Studio / OpenClaw loops (tools, JSON, code edit, self-retry) vs single-shot chat? Suffix only pays on the first class.
2. **Next idle-window experiment:** stock `ngram-mod,draft-mtp` alias on Qwen3.8, or jump to standing up a Windows SYCL *build* environment so a suffix branch is even possible?
3. **gpt-oss-20b sandbox:** the 12.1 GB Unsloth Q8_0 is already on `D:\`. Next idle window: add a llama-swap alias (one card, stock b10488, ngram-mod) vs keep it unwired and do suffix work only on Qwen3.8?

## If we later implement, smallest PR-shaped steps

1. Confirm oneAPI + `win-build-sycl.bat` can produce a binary that matches b10488 Qwen3.8 MTP numbers (gate: no suffix yet).
2. Stock-binary alias `qwen3.8-27b-ngram` (`--spec-type ngram-mod,draft-mtp`). Bench easy/hard + warm repeat + one Agent Studio trace.
3. Port ik_llama `suffix-tree.{h,cpp}` onto that custom llama.cpp, `--spec-type suffix,draft-mtp`, optional corpus file.
4. Optional: `gpt-oss-20b` one-card alias, suffix/ngram only (no EAGLE-3 in v1).
5. Promote an alias into the default id only if it wins on both easy and hard.

## Key decisions (proposed, not executed)

- The April suffix code lives in **ik_llama.cpp#1646**, not ggml-org/llama.cpp. Use it as a **source to port**, not as the Zeus runtime.
- Stay on llama.cpp SYCL; fork *mainline* near b10488; keep official zips as production.
- Suffix drafter is CPU-only; SYCL only has to verify, which it already does for MTP.
- Gate the custom build: “same Qwen3.8 t/s as b10488” before adding suffix.
- Prefer **gpt-oss-20b** over 120B as a suffix sandbox. Weights already local (12.1 GB Unsloth Q8_0). Keep Qwen3.8 as the quality daily driver.
- Skip EAGLE-3 on gpt-oss until model-free spec is measured (upstream reports MoE EAGLE-3 can be net-negative in llama.cpp).
- Judge success on **agentic/repetitive traces**, not chat.

## Community impact (if we ever upstream)

This would help people **if** the suffix tree lands in **ggml-org/llama.cpp**, not if it stays a Zeus-only fork.

vLLM already has the paper (Arctic `method: suffix`). ik_llama already has a CPU suffix type. The hole is **mainline llama.cpp**: everyone on SYCL/CUDA/Metal/Vulkan who already uses `--spec-type ngram-mod` has no suffix tree and no `suffix_corpus`. Agentic loops (OpenClaw, Continue, Aider, SWE-agent) are exactly the paper’s workload, and those users live on llama.cpp more than vLLM.

Highest-leverage artifact, in order:

1. **Upstream `--spec-type suffix` + corpus** into llama.cpp, with tests and `docs/speculative.md`. That is the whole local-AI win. Backend-agnostic CPU drafter; every vendor inherits it.
2. **Measured Arc Pro B70 / Windows SYCL numbers** for Qwen3.8 MTP vs ngram-mod vs suffix, and gpt-oss-20b one-card. Public B70 data is still sparse; honest regressions (verify cost eating the draft) are as useful as speedups. Feed the Intel XPU cookbook crowd.
3. **Negative results.** Zeus already learned MTP can be net-negative on older SYCL. Publishing “suffix lost on hard-reason, won on warm JSON” stops cargo-cult 5.3× claims.

What is *not* a community contribution: a private ik_llama SYCL binary, a Windows vLLM science project, or EAGLE-3 on gpt-oss after upstream already warned it can be slower.

If we revisit: keep production on stock b10488; treat the suffix branch as something we’d try to PR, not a local patch forever.

## Where this file lives

- This repo: `docs/PLAN.md`
- Desktop snapshot: `C:\Users\jstaples2\Desktop\SuffixDecoding-Zeus-plan.md`
