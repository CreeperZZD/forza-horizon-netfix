@echo off
setlocal
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges, please click YES in the UAC window...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
echo ============================================
echo   Forza Horizon 4/5 Network Fix
echo ============================================
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ForzaHorizonNetFix.ps1" -Action Fix
echo.
echo Finished. Please REBOOT your PC, then run Run-Status.bat to verify.
echo.
pause