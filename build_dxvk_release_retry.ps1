<#
  build_dxvk_release_retry.ps1 — run the release build, auto-retrying past the
  known intermittent slangc.exe / cl.exe access-violation (0xC0000005) crashes.

  Why this exists: heavy parallel compilation crashes intermittently under memory
  pressure. scripts-common/compile_shaders.py runs one slangc.exe per CPU core, and
  ninja runs one cl.exe per core for C++. NVIDIA's own comment in compile_shaders.py
  notes "occasional crashes of slangc.exe on the build farm" (their retry is disabled,
  maxAttempts=1). Observed here: the SAME shader crashed after 108s under load then
  compiled in 3.78s on a low-contention retry, and cl.exe crashed too -> this is
  contention / system memory pressure, NOT a per-shader or dxvk-remix bug.

  The build is incremental (compile_shaders.py mtime-checks each variant; ninja resumes
  from cached .obj/.spv), so every re-run has fewer targets left -> less contention ->
  it converges. This wrapper just loops build_dxvk_release.ps1 until the final
  _Comp64Release\src\d3d9\d3d9.dll is produced, or until progress plateaus.

  Upstream build scripts are NOT modified. Each build runs in a CHILD powershell
  process so PerformBuild's `exit` (build_common.ps1) can't kill this loop.
#>
param([int]$MaxAttempts = 20)

$ErrorActionPreference = 'Continue'
$root     = (Get-Location).Path
$artifact = Join-Path $root '_Comp64Release\src\d3d9\d3d9.dll'
$buildDir = Join-Path $root '_Comp64Release'

function Get-BuildProgress {
    if (-not (Test-Path $buildDir)) { return 0 }
    $spv = @(Get-ChildItem -Path $buildDir -Recurse -Filter *.spv -File -ErrorAction SilentlyContinue).Count
    $obj = @(Get-ChildItem -Path $buildDir -Recurse -Filter *.obj -File -ErrorAction SilentlyContinue).Count
    return ($spv + $obj)
}

$noProgress = 0
for ($i = 1; $i -le $MaxAttempts; $i++) {
    $before = Get-BuildProgress
    Write-Host ''
    Write-Host ("=== build attempt {0}/{1}  (compiled outputs so far: {2}) ===" -f $i, $MaxAttempts, $before) -ForegroundColor Cyan

    # Child process: isolates PerformBuild's `exit` on a crashed sub-step from this loop.
    & powershell -NoProfile -ExecutionPolicy Bypass -File .\build_dxvk_release.ps1
    $childExit = $LASTEXITCODE

    if (Test-Path $artifact) {
        Write-Host ''
        Write-Host ("SUCCESS on attempt {0}. Artifact produced:" -f $i) -ForegroundColor Green
        Write-Host ("  {0}" -f $artifact) -ForegroundColor Green
        exit 0
    }

    $after = Get-BuildProgress
    $delta = $after - $before
    Write-Host ("attempt {0}: child exit {1}; compiled outputs {2} -> {3} (+{4}); final DLL not produced yet" -f $i, $childExit, $before, $after, $delta) -ForegroundColor Yellow

    if ($delta -le 0) { $noProgress++ } else { $noProgress = 0 }
    if ($noProgress -ge 3) {
        Write-Host ''
        Write-Host 'Three consecutive attempts made ZERO progress. That is not an intermittent crash - the same step is failing every time. Stopping so we investigate that specific step instead of looping forever.' -ForegroundColor Red
        exit 2
    }
}

Write-Host ''
Write-Host ("Reached MaxAttempts ({0}) without producing the final DLL." -f $MaxAttempts) -ForegroundColor Red
Write-Host 'If compiled-output counts were still climbing each attempt, just run this again to continue. If they plateaued, the machine is likely memory-unstable under heavy parallel load (see build notes).' -ForegroundColor Red
exit 1
