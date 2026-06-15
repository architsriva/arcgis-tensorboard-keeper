@echo off
setlocal
set SCRIPT_DIR=%~dp0
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%archive\start.ps1" %*
echo.
echo If the browser did not open, go to http://localhost:6015/?darkMode=true#timeseries
pause
