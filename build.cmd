@echo off
REM Build/run sni-lua inside the MSVC developer environment.
REM LuaJIT's vendored build (msvcbuild.bat) requires a full MSVC dev shell,
REM not just cl.exe on PATH -- it invokes the freshly built `minilua` by bare
REM name. vcvars64 sets up the environment so that works.

set "VCVARS=C:\Program Files\Microsoft Visual Studio\18\Enterprise\VC\Auxiliary\Build\vcvars64.bat"
if not exist "%VCVARS%" (
  echo [build.cmd] vcvars64.bat not found at "%VCVARS%"
  exit /b 1
)

call "%VCVARS%" >nul
if errorlevel 1 (
  echo [build.cmd] failed to initialize MSVC environment
  exit /b 1
)

REM LuaJIT's vendored msvcbuild.bat invokes the just-built `minilua` by bare
REM name, relying on cmd.exe resolving it from the current directory. This
REM machine has NoDefaultCurrentDirectoryInExePath=1 set, which disables that
REM and breaks the LuaJIT build. Clear it for child processes.
set "NoDefaultCurrentDirectoryInExePath="

REM Pass all args through to cargo, e.g.:
REM   build.cmd check --workspace
REM   build.cmd run --release
cargo %*
