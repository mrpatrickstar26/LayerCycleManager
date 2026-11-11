@echo off
chcp 65001 >nul
py -3 "%~dp0memory_index.py" %* 2>&1
exit /b %errorlevel%
