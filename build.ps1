# Build/run sni-lua from PowerShell.
#
# See build.cmd for the rationale: we do NOT use vcvars64 (it overflows PATH
# when chained, and is unnecessary). The only requirement for the vendored
# LuaJIT build is that NoDefaultCurrentDirectoryInExePath is unset so
# msvcbuild.bat can run the freshly built `minilua` by bare name.
#
# Usage:
#   .\build.ps1 run --release
#   .\build.ps1 check --workspace
#   .\build.ps1 test -p sni-cache

$env:NoDefaultCurrentDirectoryInExePath = $null
& cargo @args
exit $LASTEXITCODE
