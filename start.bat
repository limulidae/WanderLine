@echo off
chcp 65001 >nul
cd /d "%~dp0"
rem iOS 17+ needs admin rights for the developer tunnel
net session >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
if not exist .venv\Scripts\python.exe (
  echo First run: installing...
  python -m venv .venv || (echo Python 3.10+ is required: https://www.python.org/downloads/ & pause & exit /b 1)
  .venv\Scripts\python -m pip install --upgrade pip
  .venv\Scripts\python -m pip install -r requirements.txt || (pause & exit /b 1)
)
title WanderLine
.venv\Scripts\python -m wanderline
pause
