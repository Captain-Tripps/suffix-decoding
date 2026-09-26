# Host-RAM shadow (compute-runtime#986) on the Windows B70 rig (2026-08-27)

Context: `intel/compute-runtime#986` — a Level Zero process that sees **both** GPUs
commits ~1 GB host RAM per 1 GB VRAM (ratio ~0.98); pinned to **one** GPU the ratio
drops to ~0.14. Linux-only reported. Question: does it apply on this Windows rig,
and does single-GPU pinning (`ONEAPI_DEVICE_SELECTOR=level_zero:0`) fix it?

## Measurements (32 GB host, 30.9 GB usable, 106 GB commit limit)

| state | free physical | committed | model's committed cost | ratio vs VRAM |
|---|---|---|---|---|
| no model (OS baseline) | 20.9 GB | 18.4 GB | — | — |
| `qwen3.8-27b-q6-1card` (1 card, Q6 ~23 GB) | 18.2 GB | 49.9 GB | **+31.5 GB** | **1.37** |
| `qwen3.8-27b-ngram` (2 cards, Q8 ~27 GB) | 17.3 GB | 58.1 GB | **+39.7 GB** | **1.47** |

Decode: q6-1card **27.6 t/s** vs two-card Q8 ~28 t/s — **no meaningful loss**.
Prefill q6-1card 259 t/s. Load 22 s.

## Findings

1. **The shadow is real on Windows.** A model commits ~1.4× its VRAM size in host
   memory, invisible to working-set / "in use" accounting (llama-server shows a
   ~3 GB working set while committing ~40 GB).
2. **Single-GPU pinning does NOT fix it on Windows.** Pinned ratio 1.37 vs unpinned
   1.47 — nowhere near Linux's 0.14. The #986 "one GPU per worker" mitigation does
   not translate to the WDDM/DCH driver. `ONEAPI_DEVICE_SELECTOR` changes which
   devices SYCL *uses*, not the driver's per-adapter commit behavior.
3. **But committed != the crash trigger.** The RAM-exhaustion incidents were
   *resident* (free physical -> <1 GB) exhaustion + pagefile thrash. q6-1card only
   drops free physical by ~2.7 GB vs the OS baseline (weights live in VRAM; only
   host-side buffers are resident). The committed number is alarming but mostly
   paged out.

## Move 1 verdict — keep it

`qwen3.8-27b-q6-1card`: same decode speed, ~8 GB less committed, ~1 GB more free
physical, and it physically frees card 1. Q6_K_XL quality is close to Q8. A viable
one-card prose option. Downsides: 49k context cap (vs 131k), Q6 vs Q8.

## Move 2 (concurrent two-model) — still needs live monitoring

Pinning doesn't buy the safety margin #986 promised. On paper q6-1card (31.5 GB
committed) + gpt-oss-20b (~17 GB committed) = ~67 GB committed, under the 106 limit,
and *resident* might stay fine (~16 GB free physical) — but this is the exact
configuration and failure mode of the Aug-4 incident. Do it only with:
- live `free physical` + `committed` polling during load AND ~5 min idle after
  (the incident fired on an idle timer, not at load)
- the backup config staged and llama-swap restart ready as rollback
- a human watching

## The clean fix

**64 GB host RAM (~$100 DDR5).** The shadow is ~1.4× VRAM and unavoidable on
Windows. With 64 GB: gpt-oss-120b full-offload works, concurrent models are
comfortable, and the commit limit stops being the design constraint. Highest ROI
item for pushing these cards further.
