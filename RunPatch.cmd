@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Patch-G1R-UE4SS.ps1"
echo.
pause
