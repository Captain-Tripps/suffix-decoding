# Make the custom SYCL llama-server self-contained (b10488-style): copy the
# oneAPI 2026 runtime DLLs next to the exe so it never touches the broken
# 0-byte compiler\2026.0\bin\umf.dll. Sources are read-only Program Files;
# dest is the user-writable runtime dir.
$ErrorActionPreference = "Stop"
$O    = "C:\Program Files (x86)\Intel\oneAPI"
$dest = "C:\Users\jstaples2\AI\Runtimes\llama.cpp\suffix-sycl"

# name -> source dir. umf.dll deliberately from the umf component (compiler copy is 0 bytes).
$files = @{
  "sycl9.dll"                     = "$O\compiler\2026.0\bin"
  "sycl-jit.dll"                  = "$O\compiler\2026.0\bin"
  "ur_loader.dll"                 = "$O\compiler\2026.0\bin"
  "ur_adapter_level_zero.dll"     = "$O\compiler\2026.0\bin"
  "ur_adapter_level_zero_v2.dll"  = "$O\compiler\2026.0\bin"
  "ur_adapter_opencl.dll"         = "$O\compiler\2026.0\bin"
  "ur_win_proxy_loader.dll"       = "$O\compiler\2026.0\bin"
  "libmmd.dll"                    = "$O\compiler\2026.0\bin"
  "svml_dispmd.dll"               = "$O\compiler\2026.0\bin"
  "libiomp5md.dll"                = "$O\compiler\2026.0\bin"
  "intelocl64.dll"               = "$O\compiler\2026.0\bin"
  "common_clang64.dll"           = "$O\compiler\2026.0\bin"
  "OpenCL.dll"                    = "$O\compiler\2026.0\bin"
  "umf.dll"                       = "$O\umf\1.1\bin"          # <-- good copy
  "libhwloc-15.dll"              = "$O\tcm\1.5\bin"
  "tbb12.dll"                     = "$O\tbb\latest\bin"
  "tbbmalloc.dll"                = "$O\tbb\latest\bin"
  "dnnl.dll"                      = "$O\dnnl\latest\bin"
}
# MKL: whatever mkl_sycl_blas.* / mkl_core.* / mkl_tbb_thread.* exist
Get-ChildItem "$O\mkl\latest\bin" -Filter "mkl_sycl_blas.*.dll" | ForEach-Object { $files[$_.Name] = $_.DirectoryName }
Get-ChildItem "$O\mkl\latest\bin" -Filter "mkl_core.*.dll"      | ForEach-Object { $files[$_.Name] = $_.DirectoryName }
Get-ChildItem "$O\mkl\latest\bin" -Filter "mkl_tbb_thread.*.dll"| ForEach-Object { $files[$_.Name] = $_.DirectoryName }

$copied = 0; $missing = @()
foreach ($name in $files.Keys) {
  $src = Join-Path $files[$name] $name
  if (Test-Path $src) {
    $s = Get-Item $src
    if ($s.Length -eq 0) { $missing += "$name (0 bytes at $($s.FullName))"; continue }
    Copy-Item $src (Join-Path $dest $name) -Force
    $copied++
  } else { $missing += "$name (not found in $($files[$name]))" }
}
# SYCL device-lib SPIR-V blobs
Get-ChildItem "$O\compiler\2026.0\bin" -Filter "libsycl-*.spv" -ErrorAction SilentlyContinue | ForEach-Object { Copy-Item $_.FullName $dest -Force; $copied++ }

"copied $copied files to $dest"
if ($missing) { "MISSING:"; $missing | ForEach-Object { "  $_" } }
"`nnote: ze_loader.dll intentionally NOT bundled - taken from System32 (Intel driver), same as b10488."
