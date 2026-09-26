@echo off
setlocal enabledelayedexpansion
call "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Auxiliary\Build\vcvars64.bat" || exit /b 1

rem --- oneAPI env (2026.0) ---
rem The top-level setvars.bat dispatcher is broken on this box (its per-component
rem loop fails with "'vars.bat' is not recognized"). The component vars.bat
rem scripts work when called directly, deps (tbb/umf) before compiler.
rem Intel's VS detector also needs VSxxxxINSTALLDIR for VS 18 (2026).
set "VS2026INSTALLDIR=C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools"
set "VS2022INSTALLDIR=C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools"
set "ONEAPI=C:\Program Files (x86)\Intel\oneAPI"
for %%C in (tbb umf dnnl mkl dpl ocloc compiler) do (
  if exist "%ONEAPI%\%%C\latest\env\vars.bat" call "%ONEAPI%\%%C\latest\env\vars.bat" >nul 2>&1
)
where icx >nul 2>&1 || (echo ERROR: icx not on PATH after oneAPI env setup & exit /b 1)
echo oneAPI compiler: & icx --version

set SRC=C:\Users\jstaples2\Projects\llama.cpp-b70fix
set BUILD=%SRC%\build-sycl
set DEST=C:\Users\jstaples2\AI\Runtimes\llama.cpp\b70fix-sycl
set ICX=%ONEAPI%\compiler\latest\bin\icx.exe

cmake -B "%BUILD%" -S "%SRC%" -G Ninja ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DGGML_SYCL=ON ^
  -DGGML_SYCL_F16=ON ^
  -DCMAKE_C_COMPILER=cl ^
  -DCMAKE_CXX_COMPILER="%ICX%" ^
  -DBUILD_SHARED_LIBS=ON ^
  -DLLAMA_OPENSSL=OFF ^
  -DCMAKE_CXX_FLAGS_RELEASE="/O2 /DNDEBUG"
if errorlevel 1 exit /b 1

cmake --build "%BUILD%" --config Release -j %NUMBER_OF_PROCESSORS% --target llama-server
if errorlevel 1 exit /b 1

if not exist "%DEST%" mkdir "%DEST%"
copy /Y "%BUILD%\bin\*.exe" "%DEST%\"
copy /Y "%BUILD%\bin\*.dll" "%DEST%\"

rem Bundle the oneAPI 2026 runtime DLLs next to the exe (b10488-style) so the
rem binary is self-contained and never hits the broken 0-byte
rem compiler\2026.0\bin\umf.dll that this install shipped.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0stage-runtime-b70fix.ps1"
if errorlevel 1 exit /b 1

echo Built to %DEST%
dir "%DEST%\llama-server.exe"
endlocal
