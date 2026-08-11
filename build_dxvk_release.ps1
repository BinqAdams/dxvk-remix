<#
  build_dxvk_release.ps1 — build ONLY the normal release renderer (no Tracy twin).

  Output:
    _Comp64Release/src/d3d9/d3d9.dll (+ .pdb)  = the ACTIVE renderer

  Deploy (manual Copy-Item, back up the live files first — see the painkiller_dev
  changelog / build_dxvk_remix_workflow memory):
    _Comp64Release/src/d3d9/d3d9.dll  -> Bin/.trex/d3d9.dll
    _Comp64Release/src/d3d9/d3d9.pdb  -> Bin/.trex/d3d9.pdb

  Run from the repo root (build_common.ps1 uses Get-Location for its build dirs).
  Per the build rule, delete stale _Comp64Release dirs before a clean build.
  Use build_dxvk_both.ps1 when you also need the Tracy profiling twin (it builds
  this same _Comp64Release plus a _Comp64ReleaseTracy twin in one pass).
  The bridge is unaffected; rebuild it only when the renderer/bridge IPC ABI changes.
#>

. ".\build_common.ps1"

# Active renderer (normal, no Tracy).
PerformBuild -BuildFlavour release -BuildSubDir _Comp64Release -Backend ninja -EnableTracy false
