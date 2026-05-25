@echo off
set "APPDIR=%~dp0"
cd /d "%APPDIR%"
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File "%APPDIR%ExpenseSavingsTracker.ps1" 1>"%APPDIR%tracker-data\launch.log" 2>&1
if errorlevel 1 (
  echo.
  echo Expense Savings Tracker could not start.
  type "%APPDIR%tracker-data\launch.log"
  pause
)
