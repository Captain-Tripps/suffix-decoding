# Upstream path

The C++ change we want in the world is a **llama.cpp PR**, not a permanent Zeus fork.

## Do not

- Push suffix work onto `Captain-Tripps/llama.cpp` as-is. That fork of ggml-org/llama.cpp was last touched 2026-06-28 and is not the SYCL b10488 line Zeus runs.
- Vendor all of llama.cpp into this repo.

## Do

1. Clone `ggml-org/llama.cpp` at a tag near **b10488** into a gitignored `vendor/llama.cpp` (or a sibling directory).
2. Port ik_llama `common/suffix-tree.{h,cpp}` onto that tree’s current speculative API (`--spec-type` comma list, two-stage with `draft-mtp`).
3. Build Windows SYCL with oneAPI (`examples/sycl/win-build-sycl.bat`), NDEBUG, install **beside** `b10488`, never over it.
4. Gate: custom binary matches stock Qwen3.8 MTP n-max 3 t/s before suffix is added.
5. If suffix wins on the bench protocol in `benches/README.md`, open a PR to ggml-org/llama.cpp with tests + `docs/speculative.md`.

ik_llama will not cherry-pick. Reimplement against today’s callbacks; keep linear drafts for v1 (no tree verify).
