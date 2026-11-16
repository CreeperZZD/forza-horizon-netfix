@echo off
echo ============================================
echo   Teredo Status
echo ============================================
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ForzaHorizonNetFix.ps1" -Action Status
echo.
pause