@echo off
setlocal
cd /d "%~dp0"
echo ============================================================
echo   dxvk-remix RELEASE build  (auto-retry past slangc/cl crashes)
echo ============================================================
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ts = Get-Date -Format 'yyyy-MM-dd_HHmmss'; $log = '_build_release_retry_' + $ts + '.log'; Write-Host ('Logging to: ' + $log); & .\build_dxvk_release_retry.ps1 *>&1 | Tee-Object -FilePath $log; Write-Host ''; Write-Host ('Finished. Full log: ' + $log)"
echo.
pause
endlocal
