# Build and package a ready-to-run sni-lua release for Windows.
#
# Produces  dist/sni-lua-<version>-windows-x86_64.zip  containing the
# stripped release binary plus examples, docs, README and LICENSE.
#
# Usage (from the repo root):
#   .\scripts\package.ps1
#   .\scripts\package.ps1 -Version 0.1.0      # override the inferred version
#
# Requires the MSVC toolchain (the `cc` crate finds it via the registry; no
# vcvars shell needed). Mirrors build.ps1: the only thing the vendored LuaJIT
# build needs is NoDefaultCurrentDirectoryInExePath unset so msvcbuild.bat can
# invoke the freshly built `minilua` by bare name.

param(
    [string]$Version = ""
)

$ErrorActionPreference = "Stop"
$env:NoDefaultCurrentDirectoryInExePath = $null

# Run from the repo root regardless of where the script is invoked from.
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

if (-not $Version) {
    # Infer from the workspace [workspace.package] version.
    $cargo = Get-Content "Cargo.toml" -Raw
    if ($cargo -match '(?m)^\s*version\s*=\s*"([^"]+)"') {
        $Version = $Matches[1]
    } else {
        throw "could not infer version from Cargo.toml; pass -Version"
    }
}

$target = "x86_64-pc-windows-msvc"
$name   = "sni-lua-$Version-windows-x86_64"
$staging = "dist/$name"

Write-Host "Building sni-lua $Version (release, $target)..." -ForegroundColor Cyan
& cargo build --release --bin sni-lua
if ($LASTEXITCODE -ne 0) { throw "cargo build failed" }

$exe = "target/release/sni-lua.exe"
if (-not (Test-Path $exe)) { throw "expected binary not found: $exe" }

Write-Host "Staging $staging ..." -ForegroundColor Cyan
if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
New-Item -ItemType Directory -Force -Path $staging | Out-Null

Copy-Item $exe              -Destination "$staging/sni-lua.exe"
Copy-Item "README.md"       -Destination $staging
Copy-Item "LICENSE"         -Destination $staging
Copy-Item -Recurse "examples" -Destination "$staging/examples"
New-Item -ItemType Directory -Force -Path "$staging/docs" | Out-Null
Copy-Item "docs/SCRIPTING.md" -Destination "$staging/docs/"



$zip = "dist/$name.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Write-Host "Compressing $zip ..." -ForegroundColor Cyan
Compress-Archive -Path "$staging/*" -DestinationPath $zip

$size = "{0:N1} MB" -f ((Get-Item $zip).Length / 1MB)
Write-Host "Done: $zip ($size)" -ForegroundColor Green
