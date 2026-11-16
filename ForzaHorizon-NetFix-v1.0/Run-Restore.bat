@echo off
setlocal
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges, please click YES in the UAC window...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
echo ============================================
echo   Restore network settings (e.g. for Multisim)
echo ============================================
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ForzaHorizonNetFix.ps1" -Action Restore
echo.
pause