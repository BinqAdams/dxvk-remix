@echo off
setlocal
cd /d "%~dp0"
echo ============================================================
echo   dxvk-remix RELEASE build (no Tracy twin)
echo ============================================================
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ts = Get-Date -Format 'yyyy-MM-dd_HHmmss'; $log = '_build_release_' + $ts + '.log'; Write-Host ('Logging to: ' + $log); & .\build_dxvk_release.ps1 *>&1 | Tee-Object -FilePath $log; Write-Host ''; Write-Host ('Build finished. Full log: ' + $log)"
echo.
pause
endlocal
