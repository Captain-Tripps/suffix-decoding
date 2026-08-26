# Experiment configs

These are **snippets**, not the live `C:\llama-swap\config.windows.yaml`.

Copy a block into llama-swap as a **new id**. Restart the llama-swap Windows service only after a yaml backup (see `docs/SAFETY.md`).

| File | Intent |
|---|---|
| `qwen38-ngram-mtp.yaml` | Stock b10488, Qwen3.8 Q8, `ngram-mod` then `draft-mtp` n-max 3 |
| `gpt-oss-20b-ngram.yaml` | One-card gpt-oss-20b, `ngram-mod` only |

Do not replace the production `qwen3.8-27b` entry with these.
