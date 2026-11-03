@echo off
rem Doki launcher: asks for administrator (UAC), then starts the app.
rem   Start.bat         normal start (console hidden)
rem   Start.bat debug   keep the console visible to see errors
setlocal
cd /d "%~dp0"

set "WK_MODE=%~1"
if /i "%WK_MODE%"=="elevated" set "WK_MODE=%~2"

net session >nul 2>&1
if %errorlevel%==0 goto run
if /i "%~1"=="elevated" goto run

rem Not admin yet: relaunch elevated. If the user says No, continue without admin (limited mode).
powershell -NoProfile -Command "try { Start-Process -FilePath '%~f0' -ArgumentList 'elevated %WK_MODE%' -Verb RunAs -ErrorAction Stop; exit 0 } catch { exit 1 }"
if %errorlevel%==0 goto :eof

:run
if /i "%WK_MODE%"=="debug" (
    powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0app\main.ps1"
    pause
    goto :eof
)
start "" powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0app\main.ps1"
endlocal
