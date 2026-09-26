# Suffix corpus preload — Heirloom Ch2 cold-generation test (2026-08-26)

**Result: no measurable benefit.** Pre-warming the suffix tree with the previous
chapter + bible + seed does not speed up cold prose generation.

## Setup

Generate Chapter 2 of *Heirloom of the Ironwood Grove* from its real beat plan
(`chapters/02/module3_output.md`), temp 0.7, seed 1, ~1100 words. Through llama-swap
so it manages the model swaps. `scripts/bench-corpus-swap.ps1`, raw
`results/bench-corpus-swap-20260826-195759.jsonl`.

Corpus (`C:\llama-swap\corpus\current.json`, ~24k tokens): `chapter_01.md` final
prose + `story-bible.json` + `seed.md`.

## Decode t/s (draft accepted / drafted)

| config | pass 1 | pass 2 | draft accept |
|---|---|---|---|
| A  `qwen3.8-27b` (MTP control) | 28.4 | 28.4 | 53% |
| B  `qwen3.8-27b-ngram` | 28.4 | 29.0 | 53-56% |
| C  `suffix,draft-mtp` + Heirloom corpus | 26.3 | 26.8 | 52% |
| D  `suffix,draft-mtp` + `[]` corpus (control) | 27.3 | 28.4 | 51-58% |

## Findings

1. **Corpus preload does nothing here.** C (24k-token corpus) ≈ D (empty corpus) ≈
   A (plain MTP), all ~27-29 t/s. If anything C is marginally slowest.
2. **Draft acceptance is ~52-56% for every method** — that is the temp-0.7 ceiling
   on genuinely novel prose. MTP alone already hits it; ngram and suffix+corpus add
   nothing on top.
3. **Why a perfect corpus still doesn't help:** generating new prose is not
   reproducing text. The model makes a fresh stochastic sampling choice at every
   step. A corpus trie can draft `Rowan` when the context forces it, but the
   sentence structure, verb choices, and dialogue are all newly sampled. The
   exact-repeat fraction in fresh temp-0.7 prose is small, and MTP already covers it.
4. The corpus feature is wired and running (C vs D produced different draft counts,
   so the tree was populated) — it just does not move the needle for this workload.
   Confirmation of the `loaded suffix corpus` log line was not captured this run
   (llama-swap logging changed after the restart); a standalone load can confirm
   token count if certainty is needed.

## Bottom line for bespoke-books

- **Do not route M4 / cold-prose Q8 calls through any speculative alias.** Plain
  `qwen3.8-27b` == `-ngram` == `-suffix-corpus` for fresh prose (~28 t/s). The
  earlier ngram M4 canary's apparent -16% was an output-length confound; per-token
  rate is flat.
- **Speculative decoding pays only on** low-temp structured passes (JSON, validators,
  continuity, ledger extraction) and warm rewrites that literally re-emit spans. If
  those run on Q8, route *them* to `qwen3.8-27b-ngram`.
- **Bigger lever for M4:** prefill of the re-fed bible/style context — prompt
  caching / stable-prefix call structure, not speculation.

## suffix corpus feature status

Tokenizer wiring complete (`llama.cpp-suffix` `4be28d6`), builds, loads. Negative
result for creative prose. Would still plausibly help a cold *agentic* workload
(tool JSON, code, self-refine at low temp) — the paper's actual target — but that
is not this pipeline. Park unless a low-temp cold-start use case appears.
