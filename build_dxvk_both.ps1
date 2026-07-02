<#
  build_dxvk_both.ps1 — build the normal renderer AND a Tracy-instrumented twin
  in one pass, so the profiling build is always available and in sync.

  Outputs:
    normal -> _Comp64Release/src/d3d9/d3d9.dll (+ .pdb)      = the ACTIVE renderer
    tracy  -> _Comp64ReleaseTracy/src/d3d9/d3d9.dll (+ .pdb) = the profiling twin

  Deploy (manual Copy-Item, back up the live files first — see the painkiller_dev
  changelog / build_dxvk_remix_workflow memory):
    _Comp64Release/src/d3d9/d3d9.dll       -> Bin/.trex/d3d9.dll
    _Comp64Release/src/d3d9/d3d9.pdb       -> Bin/.trex/d3d9.pdb
    _Comp64ReleaseTracy/src/d3d9/d3d9.dll  -> Bin/.trex/d3d9.dll.tracy
    _Comp64ReleaseTracy/src/d3d9/d3d9.pdb  -> Bin/.trex/d3d9.pdb.tracy

  Run from the repo root (build_common.ps1 uses Get-Location for its build dirs).
  Per the build rule, delete stale _Comp64Release* dirs before a clean build.
  The bridge is unaffected (Tracy is renderer-side); rebuild it only when the
  renderer/bridge IPC ABI actually changes.
#>

. ".\build_common.ps1"

# Active renderer (normal).
PerformBuild -BuildFlavour release -BuildSubDir _Comp64Release      -Backend ninja -EnableTracy false

# Profiling twin (Tracy client on, separate build dir so it never clobbers active).
PerformBuild -BuildFlavour release -BuildSubDir _Comp64ReleaseTracy -Backend ninja -EnableTracy true
