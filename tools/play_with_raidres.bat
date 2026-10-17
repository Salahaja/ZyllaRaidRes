@echo off
rem Start the RaidRes watcher hidden, then the game. The watcher quits by
rem itself once the game closes, so there is nothing to stop afterwards.
rem
rem   play_with_raidres.bat            launches WoW.exe through VanillaFixes
rem   play_with_raidres.bat WoW2.exe   the second client
rem
rem Its log is CustomData\RaidResBridge_watcher.log.
setlocal
set "TOOLS=%~dp0"
for %%I in ("%~dp0..\..\..\..") do set "CLIENT=%%~fI"
set "GAME=%~1"
if "%GAME%"=="" set "GAME=WoW.exe"

rem pythonw has no console window; pyw is the same thing via the py launcher.
set "PYW=pythonw"
where pythonw >nul 2>nul || set "PYW=pyw"

start "" "%PYW%" "%TOOLS%raidres_bridge.py" watch --with-game

rem VanillaFixes is what loads nampower.dll, which the addon needs.
start "" /D "%CLIENT%" "%CLIENT%\VanillaFixes.exe" %GAME%
