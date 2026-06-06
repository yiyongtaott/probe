@echo off
chcp 65001 >nul
setlocal

REM ===== UltraLightProbe native build =====
REM Usage:
REM   build.bat                       -> silent GUI            -> bin\probe.exe       (device=notebook)
REM   build.bat desktop               -> silent GUI, desktop   -> bin\probe-desktop.exe (device=desktop)
REM   build.bat phone                 -> silent GUI, phone     -> bin\probe-phone.exe   (device=phone)
REM   build.bat debug                 -> console, notebook     -> bin\probe-console.exe (device=notebook)
REM
REM Device ID = exe name after the last "-" before .exe:
REM   probe.exe            -> notebook (no "-", default)
REM   probe-notebook.exe   -> notebook
REM   probe-desktop.exe    -> desktop
REM   probe-phone.exe      -> phone
REM   probe-anything.exe   -> anything

set "MODE=%~1"

REM Use batch file's own directory as the root (%~dp0)
set "ROOT=%~dp0"
REM Remove trailing backslash from %~dp0
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"

REM --- determine build type: debug (console) or silent GUI ---
set "SUBSYSTEM=WINDOWS"
set "ENTRY=/ENTRY:wWinMainCRTStartup"
set "OUTFILE=probe"
if /i "%MODE%"=="debug" (
    set "SUBSYSTEM=CONSOLE"
    set "ENTRY=/ENTRY:mainCRTStartup"
    set "OUTFILE=probe-console"
) else if /i "%MODE%"=="desktop" (
    set "OUTFILE=probe-desktop"
) else if /i "%MODE%"=="phone" (
    set "OUTFILE=probe-phone"
)

echo [BUILD] mode=%MODE% output=%OUTFILE% subsystem=%SUBSYSTEM%
echo [BUILD] root=%ROOT%

REM --- locate vcvars64.bat (VS is at ...\VS\Com on this machine) ---
set "VCVARS=D:\aMyDrivesF\develop\VS\Com\VC\Auxiliary\Build\vcvars64.bat"
if not exist "%VCVARS%" (
    for /d %%i in ("D:\aMyDrivesF\develop\VS\*") do (
        if exist "%%i\VC\Auxiliary\Build\vcvars64.bat" set "VCVARS=%%i\VC\Auxiliary\Build\vcvars64.bat"
    )
)
if not exist "%VCVARS%" (
    for /f "usebackq tokens=*" %%p in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -property installationPath 2^>nul`) do (
        if exist "%%p\VC\Auxiliary\Build\vcvars64.bat" set "VCVARS=%%p\VC\Auxiliary\Build\vcvars64.bat"
    )
)
if not exist "%VCVARS%" (
    echo [ERROR] vcvars64.bat not found. Install VS C++ tools or fix the path in build.bat.
    goto :end
)
echo [1/3] Visual Studio: %VCVARS%
call "%VCVARS%" >nul 2>&1
where cl.exe >nul 2>&1 || ( echo [ERROR] cl.exe not on PATH after vcvars. & goto :end )

if not exist "%ROOT%\bin" mkdir "%ROOT%\bin"

set "CFLAGS=/nologo /O2 /MT /utf-8 /W3 /DUNICODE /D_UNICODE"
set "LIBS=winhttp.lib iphlpapi.lib wlanapi.lib user32.lib shell32.lib"

echo [2/3] Compiling %OUTFILE%...
if /i "%MODE%"=="debug" (
    cl %CFLAGS% /DCONSOLE_BUILD "%ROOT%\c\UltraLightProbe.c" /Fe:"%ROOT%\bin\%OUTFILE%.exe" /Fo:"%ROOT%\bin\%OUTFILE%.obj" /link %ENTRY% /SUBSYSTEM:%SUBSYSTEM% %LIBS%
) else (
    cl %CFLAGS% "%ROOT%\c\UltraLightProbe.c" /Fe:"%ROOT%\bin\%OUTFILE%.exe" /Fo:"%ROOT%\bin\%OUTFILE%.obj" /link %ENTRY% /SUBSYSTEM:%SUBSYSTEM% %LIBS%
)

if errorlevel 1 ( echo [ERROR] Build failed. & goto :end )

del /q "%ROOT%\bin\*.obj" >nul 2>&1
echo [3/3] OK -^> %ROOT%\bin\%OUTFILE%.exe
dir "%ROOT%\bin\%OUTFILE%.exe" | findstr /i "%OUTFILE%"

:end
if not defined NOPAUSE pause
endlocal
