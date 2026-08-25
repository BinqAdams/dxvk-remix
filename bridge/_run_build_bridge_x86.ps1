# Self-locating wrapper: run only the x86 client leg of the bridge build.
Set-Location $PSScriptRoot
. .\build_bridge.ps1
Build -Platform x86 -BuildFlavour release -BuildSubDir _compRelease_x86
exit $LastExitCode
