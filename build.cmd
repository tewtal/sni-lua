@echo off
setlocal
REM Build/run sni-lua.
REM
REM We deliberately do NOT call vcvars64.bat. It prepends ~2KB of tool paths
REM to PATH every invocation; chained inside cmd it overflows the ~8191-char
REM command-line limit ("The input line is too long"). It is also unnecessary:
REM the `cc` crate locates MSVC via the registry on its own, and a clean
REM LuaJIT (mlua-sys) build succeeds without a full dev shell.
REM
REM The ONLY thing the vendored LuaJIT build actually needs is for
REM NoDefaultCurrentDirectoryInExePath to be unset, so LuaJIT's msvcbuild.bat
REM can invoke the just-built `minilua` by bare name from the build dir.
REM (Clearing it here only affects this build's child processes.)
set "NoDefaultCurrentDirectoryInExePath="

REM Pass all args through to cargo, e.g.:
REM   build.cmd check --workspace
REM   build.cmd run --release
cargo %*
endlocal
