@echo off
rem ============================================================
rem  bili-gui -- module 2: graphical window
rem              top: live danmaku   bottom: input box to send danmaku
rem              toolbar: audio on/off (uses the same player as module 1)
rem
rem  Usage:
rem    bili-gui.cmd                      use defaults.room from config.json
rem    bili-gui.cmd 6                    by room id
rem    bili-gui.cmd example --volume 40  by alias defined in config.json
rem
rem  Troubleshooting (keeps a console so errors are visible):
rem    py -3 "%~dp0bili-gui.py" 6
rem ============================================================
setlocal
where pyw >nul 2>nul
if %ERRORLEVEL%==0 (
    start "" pyw -3 "%~dp0bili-gui.py" %*
) else (
    start "" py -3 "%~dp0bili-gui.py" %*
)
exit /b 0
