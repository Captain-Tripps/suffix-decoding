# `--spec-type suffix` benchmark (2026-08-26)

First real measurement of the ported suffix drafter. All four configs on the **same**
custom oneAPI-2026 binary (kernels constant, only the CPU drafter changes), Qwen3.8-27B
Q8_0, both B70s, prod flags. Prompts run in sequence in one server so the shared
suffix tree / ngram pool warms. `scripts/bench-suffix.ps1`, raw:
`results/bench-suffix-20260826-165015.jsonl`.

## Decode t/s (draft accepted / drafted)

| prompt | mtp (control) | ngram-mod+mtp | suffix+mtp | suffix alone |
|---|---|---|---|---|
| json_1  | 43.5 (18/18) | 43.6 (18/18) | **12.4** (21/31) | **23.4** (16/16) |
| json_2  | 43.4 | 43.5 | **12.8** (22/51) | **10.6** (22/45) |
| json_3v | 43.6 | 43.5 | **10.1** (21/48) | **10.3** (21/48) |
| code_1 (cold) | 44.1 (100/102) | 44.0 | 42.4 (97/104) | **15.3** (2/15) |
| code_2 (warm) | 44.1 | **96.0** (131/131) | 55.3 (128/131) | 58.4 (128/128) |
| code_3 (warm) | 44.0 | **103.2** (131/131) | 43.3 (128/163) | 58.4 (128/128) |
| refactor | 38.3 (154/195) | 38.3 | **30.4** (159/233) | **13.6** (45/108) |

no-spec baseline on this box ≈ 15 t/s.

## Findings

1. **ngram-mod+mtp is the winner.** 2.2–2.3x on warm repeats of the same code
   (96–103 vs 44), **zero regression** anywhere else — cold, JSON, and refactor all
   stay at the mtp baseline. This is the config to ship.
2. **suffix regresses hard on non-matching prompts.** JSON drops 43 -> 10–13 t/s;
   refactor 38 -> 30 (suffix+mtp) or 14 (suffix alone). The linear suffix drafter
   proposes long low-confidence drafts from weak partial matches (`min_match_len`
   default 5), and llama.cpp verifies the whole linear draft — every rejected token
   is a wasted forward pass. Acceptance ratios tell the story: 21/48, 45/108.
3. **suffix's best case still loses.** When the tree holds the exact continuation
   (code_2/3 identical to code_1): 58 t/s at 100% accept — good, but below
   ngram-mod's 96–103 on the same prompts.
4. **suffix alone is bimodal / unusable as-is:** 58 t/s with a warm exact match,
   10–15 t/s (below no-spec) otherwise. code_1 cold drafted 2/15 — barely fired.

Matches the ik_llama.cpp author's own note (plan.md): "ngram-mod often matched or
beat suffix on code/extract/story."

## What could still make suffix worth it

- **Tune it up:** `--spec-suffix-min-match-len ~16–24`, raise `--spec-suffix-*` prob
  thresholds so it only drafts on strong matches. Likely removes the regressions;
  unlikely to beat ngram-mod's warm numbers.
- **Corpus preload** (`--spec-suffix-corpus`) — *still a stub* ("tokenizer wiring
  pending"). This is the paper's actual global tree: pre-warm from prior agent tool
  JSON / code so the *first* call in a session already drafts well. That is the one
  scenario the in-session ngram pool can't cover. Finishing the tokenizer wiring is
  the only path where suffix beats ngram here.

## Recommendation

Ship the existing `qwen3.8-27b-ngram` alias (`--spec-type ngram-mod,draft-mtp`) —
it's a clean 2x on warm agent loops with no downside. Do **not** ship suffix.
Keep the suffix branch for the corpus-preload experiment if we want to chase the
paper's cold-start win later.
