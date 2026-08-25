# Self-locating wrapper: build_bridge_release.bat requires cwd = bridge\.
Set-Location $PSScriptRoot
& cmd.exe /c "D:\dxvk-remix\bridge\build_bridge_release.bat"
