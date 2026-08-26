# Scripts

Keep helpers here so benches are repeatable. Nothing in this folder should start a model until we agree the idle window is still open and llama-swap has an experiment id.

Planned:

- `bench-completion.ps1` — POST `/completion` to a llama-swap model id, record t/s + draft stats as JSONL
- `backup-llama-swap.ps1` — timestamped copy of the live yaml
