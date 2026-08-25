# Self-locating wrapper so the cwd-dependent build scripts can be invoked by
# absolute path from any shell (the dot-sourced build_common.ps1 is relative).
Set-Location $PSScriptRoot
if (Test-Path _Comp64Release) {
    Remove-Item -Recurse -Force _Comp64Release
}
& .\build_dxvk_all_ninja.ps1
