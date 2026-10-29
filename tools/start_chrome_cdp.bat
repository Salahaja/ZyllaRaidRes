@echo off
REM Start Chrome with the DevTools Protocol enabled on port 9222.
REM This lets the raidres lock script talk to Chrome without ever
REM seeing your cookies or passwords.
REM
REM Chrome 156+ blocks --remote-debugging-port on the default profile,
REM so this uses its own profile folder.  Sign into raidres once in
REM this Chrome and the session sticks (7 days).
REM
REM To use your main profile instead, make a shortcut to chrome.exe with:
REM   --remote-debugging-port=9222 --user-data-dir="<your profile path>\."
REM   (the trailing \. bypasses the check while using the same folder)

set CDP_PORT=9222
set CDP_PROFILE=%LocalAppData%\chrome-cdp-raidres

REM Try the standard install locations
for %%P in (
    "%ProgramFiles%\Google\Chrome\Application\chrome.exe"
    "%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe"
    "%LocalAppData%\Google\Chrome\Application\chrome.exe"
) do (
    if exist %%P (
        echo Starting Chrome with CDP on port %CDP_PORT%...
        echo Profile: %CDP_PROFILE%
        start "" %%P --remote-debugging-port=%CDP_PORT% --user-data-dir="%CDP_PROFILE%" https://raidres.top
        goto :done
    )
)

echo Chrome not found in the usual places.
echo Install Chrome or edit this script with the path to chrome.exe.
pause
exit /b 1

:done
echo Chrome started.  The lock script can now connect on port %CDP_PORT%.
echo.
echo If this is the first time, sign into raidres in this Chrome window.
echo The session lasts 7 days, so you won't need to sign in often.
echo.
echo Then:  python tools\raidres_lock.py watch
