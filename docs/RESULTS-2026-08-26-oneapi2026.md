# oneAPI 2026 attempt — Level Zero adapter won't load (2026-08-26)

Installed **oneAPI 2026.0.0.193** (`winget Intel.OneAPI.Toolkit`, exit 0). Its SYCL
headers have `intel_gpu_bmg_g31` (`0x0000000500800000`) + `intel_gpu_wcl`. Reverted
the 4 shim patches in `llama.cpp-suffix` (back to clean `cb9f787`), updated
`scripts/build-sycl.cmd` for the 2026 layout (deps-before-compiler loop,
`VS2026INSTALLDIR`). Clean rebuild succeeded, no warnings-as-errors.

## Blocker: the 2026 build can't use Level Zero

`sycl-ls` (2026) shows **only OpenCL** devices — no `level_zero:gpu`. The UR loader:

```
loading adapter failed with error 126: ...\ur_adapter_level_zero.dll
loading adapter failed with error 126: ...\ur_adapter_level_zero_v2.dll
loaded adapter: ur_adapter_opencl.dll        <- only this one
```

Windows error 126 = missing dependency DLL. Import scrape of
`ur_adapter_level_zero.dll` shows it needs `pti.dll`; the only `pti.dll` on the box
is `oneAPI\pti\0.12\lib\pti.dll` (from the 2025.1 install). Adding `pti\0.12\lib`
to PATH did **not** fix it — still error 126, so there is at least one more
unresolved dependency (or a version mismatch).

Consequences:
- No `ONEAPI_DEVICE_SELECTOR`: SYCL uses the OpenCL backend -> "does not use Level
  Zero backend, disabling Level Zero memory API" -> **OOM** on model load
  (`can't allocate 1.48 GB` / `failed to allocate SYCL1 buffer 14.4 GB`).
- `ONEAPI_DEVICE_SELECTOR=level_zero:*`: **no devices found**, server exits instantly.

Installed Intel Arc driver: **32.0.101.8805** (dated 2026-07-06). `ze_loader.dll`
present in DriverStore and resolvable.

## RESOLVED — root cause was a corrupt install, not the driver

`winget Intel.OneAPI.Toolkit` left **`compiler\2026.0\bin\umf.dll` as a 0-byte file**
(also `umf.lib`; only those two). `ur_adapter_level_zero.dll` imports `UMF.dll` and
Windows resolves a module's imports from its own directory first -> got the 0-byte
stub -> error 126 -> UR loader silently fell back to OpenCL. `ur_adapter_opencl.dll`
has no UMF dependency, which is why only it loaded.

Fix (no admin, no reinstall, no driver update): `scripts/stage-runtime.ps1` bundles
the oneAPI 2026 runtime next to `llama-server.exe` (b10488-style), pulling a good
`umf.dll` from the `umf\1.1` component and `libhwloc-15.dll` from `tcm\1.5`. Wired
into `build-sycl.cmd`. GPU driver 32.0.101.8805 (2026-07-06) was fine all along —
stock b10488 uses Level Zero V2 against it.

### Gate test PASSED (2026-08-26, oneAPI 2026 build + runtime bundle)

| Prompt | b10488 MTP n3 | custom 2026 MTP n3 |
|---|---|---|
| easy_count  | 43.98 | **45.0** |
| hard_code   | 43.41 | **44.1** |
| warm_repeat | 43.26 | **44.0** |
| hard_reason | 32.35 | **34.1** |

Custom binary matches/slightly beats stock. The 3x regression is gone — it was
entirely the disabled B70 arch paths. `sycl-ls` now reports
`Arc Pro B70 Graphics 20.2.0` over Level-Zero V2. Cleared to bench `--spec-type suffix`.

## Status of the two toolchains

| | Level Zero | B70 arch detected | decode |
|---|---|---|---|
| oneAPI 2025.1.1 build | works | **no** (`unknown`) -> generic kernels | ~3x slow (5 t/s no-spec) |
| oneAPI 2026.0.0 build | **broken** (adapter err 126) | yes (has enum) | can't load model |

Neither is currently usable for benching suffix.

## Options

- **A.** Debug the 2026 L0 adapter — repair/complete the 2026 toolkit install, or
  find the remaining missing runtime dep. No hardware risk.
- **B.** Update the Intel Arc GPU driver to latest — most likely single fix for the
  2026 L0 adapter (newer L0 runtime). Production blast radius (llama-swap, ComfyUI),
  needs a maintenance window + reboot. User decision.
- **C.** oneAPI 2025.2 offline installer (not on winget) — may have `bmg_g31` and
  still-working L0. Download + unknown.
- **D.** Park the custom binary. The suffix port is done & committed; it just can't
  be measured on this box now. Keep the stock-b10488 `ngram-mod` alias (+42% warm)
  as the practical win; revisit when mainline llama.cpp grows `--spec-type suffix`
  or the toolchain clears up.

Recommendation: **B, fall back to D.** The driver is ~year-current but the 2026 L0
adapter clearly wants newer; updating it is also good rig hygiene. If the user
doesn't want to touch the driver now, go D and revisit.

## Housekeeping

Production `gpt-oss-120b` healthy throughout (restored after each aborted gate run).
No llama-swap config changes. Logs: `results/build-sycl-2026.log`,
`results/gate-suffixbin-server-20260826-1626*.log`, `results/oneapi-2026-install.log`.
