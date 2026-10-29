@echo off
rem Builds RaidResHttp.dll (32-bit, static CRT), test_fetch.exe and test_local.exe.
setlocal
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars32.bat" >nul || exit /b 1
cd /d "%~dp0"
if not exist build mkdir build
set MH=external\minhook-1.3.3
set SRCS=%MH%\src\hook.c %MH%\src\buffer.c %MH%\src\trampoline.c %MH%\src\hde\hde32.c
set FLAGS=/nologo /O2 /MT /EHsc /W3 /D_WIN32_WINNT=0x0601 /I%MH%\include /Isrc /Fobuild\
cl %FLAGS% /LD src\RaidResHttp.cpp %SRCS% /Fe:build\RaidResHttp.dll /link /DEF:src\RaidResHttp.def || exit /b 1
cl %FLAGS% /LD src\RaidResLock.cpp %SRCS% /Fe:build\RaidResLock.dll /link /DEF:src\RaidResLock.def || exit /b 1
cl %FLAGS% src\test_fetch.cpp %SRCS% /Fe:build\test_fetch.exe || exit /b 1
cl %FLAGS% src\test_local.cpp %SRCS% /Fe:build\test_local.exe || exit /b 1
