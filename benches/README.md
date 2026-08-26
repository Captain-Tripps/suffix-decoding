# Benches

Compare **time-per-output-token** and **draft acceptance**, not vibes.

## Required prompt classes

| id | What it tests | Why |
|---|---|---|
| `easy_count` | Highly predictable | Upper bound (paper-like) |
| `hard_code` | Code gen | Agent-adjacent |
| `hard_reason` | Low-repeat reasoning | Must not regress vs MTP n-max 3 |
| `warm_repeat` | Same `hard_code` immediately after | Paper’s agentic loop / global tree |

Also run one real Agent Studio / tool-JSON trace when the stock A/B looks interesting.

## Success

A spec variant **wins** only if:

- easy_count and hard_code are at least as fast as production MTP n-max 3, **and**
- hard_reason is not slower in a way that would hurt daily use, **and**
- quality is unchanged (greedy or same sampling; SuffixDecoding is lossless if verification is correct)

## How (once an experiment id is loaded)

Use llama-server `/completion` timings (`prompt_n`, `predicted_tps`, `draft_n`, `draft_n_accepted`) the same way `qwen38-tune-mtp.jsonl` was captured.

Prompts live in `benches/prompts/`. Write raw JSONL under `results/` (gitignored). Summarize in `results/README.md` only if we decide to commit a table.
