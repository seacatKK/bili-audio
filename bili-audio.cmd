@echo off
rem ============================================================
rem  bili-audio -- module 1: audio-only playback of a bilibili live room
rem
rem  Usage:
rem    bili-audio.cmd                     use defaults.room from config.json
rem    bili-audio.cmd 6                   by room id
rem    bili-audio.cmd https://live.bilibili.com/6
rem    bili-audio.cmd example -Volume 40  by alias defined in config.json
rem    bili-audio.cmd -List               list aliases
rem    bili-audio.cmd 6 -Stream hls       force HLS (default auto: FLV if available)
rem    bili-audio.cmd 6 -RunForSeconds 600  stop after 600 seconds
rem
rem  Stop with Ctrl+C. Change volume while playing: Windows volume mixer.
rem ============================================================
setlocal
set "SCRIPT=%~dp0bili-audio.ps1"
set "BOMFIX=%~dp0ensure-utf8bom.ps1"

rem Windows PowerShell 5.1 can only parse this script correctly when it is saved as
rem UTF-8 with BOM. Any editor may drop the BOM, so self-heal it before every launch.
if exist "%BOMFIX%" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%BOMFIX%" "%SCRIPT%" >nul 2>nul
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
exit /b %ERRORLEVEL%
