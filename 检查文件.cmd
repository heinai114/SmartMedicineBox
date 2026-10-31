@echo off
chcp 65001 >nul
where py >nul 2>nul
if errorlevel 1 (
  python -X utf8 "%~dp0tools\check_repository.py" %*
) else (
  py -3 -X utf8 "%~dp0tools\check_repository.py" %*
)
if errorlevel 1 (
  pause
  exit /b 1
)
pause
