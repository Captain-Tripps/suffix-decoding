# Does ngram-mod make chapters shorter? (2026-08-26)

**No. Chapter length varies ~15-20% run-to-run on this rig regardless of decoder,**
from GPU floating-point nondeterminism in the MTP speculative path. ngram-mod is
not a special offender.

## The decisive number

`qwen3.8-27b` (production, MTP n-max 3), **temp 0, identical prompt, run twice:**

| run | tokens |
|---|---|
| A | 1228 |
| B | **1455** |

Same model, same greedy settings, same input — **18% length difference, completely
different text.** temp 0 is not deterministic here.

## Why

`qwen3.8-27b` itself runs MTP speculative decoding. Speculative verification does a
**batched** forward pass over multiple draft positions; plain decode is
**sequential** single-token. Batched vs sequential matmuls use different GPU kernels
and reduction orders, so logits differ in the last bits. When the top-2 token margin
is tiny, the argmax flips — and once one token differs, the whole generation
diverges. This is inherent to speculative decoding on GPU, not a bug and not
specific to ngram.

## ngram vs MTP length (Heirloom Ch2 from beats)

| | temp 0 | temp 0.7, seeds 1/2/3 |
|---|---|---|
| `qwen3.8-27b` (MTP) | 1228 | 1213, 1500\*, 1400 |
| `qwen3.8-27b-ngram` | 1251 | 1102, 1257, 1500\* |

\* hit the 1500 `max_tokens` cap.

ngram's mean is ~6% lower across these small samples, but the **between-method gap
(~6%) is smaller than the within-method run-to-run gap (~18%)**. At n=3 with this
variance they are statistically indistinguishable. At temp 0, ngram was actually
*longer* (1251 vs 1228).

## The canary (2,995 vs 4,386 words) explained

That 32% gap is bigger than decoder nondeterminism alone. The dominant cause is the
**pipeline branching differently** — 4 vs 5 continuity retries, different expansion
decisions — on top of the ~15-20% decoder variance. You cannot A/B chapter length
from single pipeline runs; the noise floor is too high.

## What to actually do

1. **Not an ngram problem.** Reverting M4 to plain `qwen3.8-27b` will not stabilise
   length — it swings 1228<->1455 on its own.
2. **If length consistency matters, enforce it in the pipeline**, not the decoder.
   Architect_Brain already has `word_count_distribution.json`,
   `beat_prose_manifest.json`, and chapter-obligation gates — that machinery is the
   right place for a min-length floor / regenerate-if-short rule.
3. A short chapter is not necessarily a worse chapter — the 975-word and 1,182-word
   temp-0.7 MTP draws are both valid samples. Judge on quality; treat length as a
   pipeline constraint.
4. Reducing the decoder nondeterminism would mean `--spec-type none` (no MTP) — ~3x
   slower, not worth it.
