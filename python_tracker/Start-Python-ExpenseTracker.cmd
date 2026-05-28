@echo off
cd /d "%~dp0"
set "BUNDLED_PY=%USERPROFILE%\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"
if exist "%BUNDLED_PY%" (
  "%BUNDLED_PY%" -m expense_tracker
) else (
  py -3 -m expense_tracker
)
if errorlevel 1 (
  echo.
  echo Expense Savings Tracker could not start.
  echo Make sure Python 3.11 or newer is installed.
  echo.
  pause
)
