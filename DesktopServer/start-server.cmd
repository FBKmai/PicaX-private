@echo off
setlocal
if not exist "%~dp0.venv\Scripts\python.exe" (
  echo Create the Python 3.11 environment first. See Docs\LanSuperResolution.md.
  exit /b 1
)
"%~dp0.venv\Scripts\python.exe" -I -B -u -X utf8 "%~dp0launch.py" %*
