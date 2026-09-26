# gpt-oss-20b Q8_0 spec-decoding bench (2026-08-26)

Single B70 (`ONEAPI_DEVICE_SELECTOR=level_zero:0`), 65k ctx, custom oneAPI-2026
binary. gpt-oss-20b has **no native MTP** -> model-free spec only. Same agent-loop
prompts in sequence. `scripts/bench-gptoss20b.ps1`,
raw `results/bench-gptoss20b-20260826-170000.jsonl`.

## Decode t/s (draft accepted / drafted)

| prompt | none | ngram-mod | suffix |
|---|---|---|---|
| json_1  | 53.6 | 53.4 | 58.4 (4/5) |
| json_2  | 53.5 | 53.1 | 131.0 (25/32) |
| json_3v | 53.8 | 53.3 | 53.0 (14/39) |
| code_1 (cold) | 53.4 | 53.0 | 53.6 (7/15) |
| code_2 (warm) | 53.3 | **211.0** (115/115) | 176.9 (119/128) |
| code_3 (warm) | 53.1 | **222.8** (115/115) | 177.5 (119/128) |
| refactor | 52.8 | 52.8 | 53.5 (26/52) |

## Findings

1. **ngram-mod is the clear winner again, and the payoff is bigger than on Qwen3.8:**
   **~4.2x** on warm code repeats (211-223 vs 53), **zero regression** on cold /
   JSON / refactor. Why bigger than Qwen3.8's 2.3x: gpt-oss-20b is a 3.6B-active
   MoE, so per-token decode is cheap and accepted drafts convert to wall-clock
   almost for free.
2. **suffix is positive but weaker** — 3.3x warm (177 vs 53), lower acceptance
   (119/128 vs ngram's 115/115), and noisy on short prompts (json_2 lucked into
   131, json_3v got nothing). Unlike Qwen3.8, suffix caused **no hard regressions**
   here — cold cases held the ~53 baseline. Cheap decode masks the wasted verify passes.
3. **Baseline is already faster than Qwen3.8** (53 vs 44 t/s, one card vs two).

## vs Qwen3.8-27B

| | Qwen3.8-27B Q8 (2 cards) | gpt-oss-20b Q8 (1 card) |
|---|---|---|
| no-spec decode | ~15 (or ~44 w/ MTP) | ~53 |
| ngram-mod warm code | 96-103 | **211-223** |
| ngram-mod cold/other | no change | no change |
| suffix | regresses JSON/refactor | no regression, weaker lift |

## Takeaway

Same conclusion for both models: **ship `ngram-mod`, not suffix.** gpt-oss-20b +
ngram-mod is the higher-ceiling combo (4x warm, faster cold, one card free for
something else) *if* output quality is acceptable for the task — untested for prose.
