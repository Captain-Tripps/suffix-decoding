# Agent-loop A/B (same day, after the +42% warm-repeat)

Stock b10488. `qwen3.8-27b` (MTP n-max 3) vs `qwen3.8-27b-ngram` (`ngram-mod,draft-mtp`). Greedy.

| Prompt | MTP-only | ngram+MTP | Notes |
|---|---|---|---|
| json_1 (cold) | 42.8 t/s 18/18 | 42.6 t/s 18/18 | JSON too short; MTP already perfect |
| json_2 | 42.8 | 40.9 | no extra drafts |
| json_3_variant | 43.1 | 42.0 | structure similar, values differ |
| code_1 (cold) | 43.3 100/102 | 41.9 100/102 | same as first A/B |
| **code_2** | 43.3 100/102 | **58.8 131/131** | **+36%** — reproduces |
| **code_3** | 42.9 100/102 | **62.2 131/131** | **+45%** |
| refactor | 37.1 156/188 | 36.6 155/190 | **no lift** — wording changed |

The hash pool wins when the next request is almost the same tokens. It does **not** help a paraphrase/refactor. That gap is what a suffix tree + frequency scoring (and later a corpus) is for.
