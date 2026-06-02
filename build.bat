@echo off
chcp 65001 >nul
setlocal

REM ===== UltraLightProbe native build =====
REM Usage:  build.bat          -> silent GUI exe   bin\probe.exe        (for shell:startup)
REM         build.bat debug    -> console exe      bin\probe-console.exe (logs, for testing)

set "MODE=%~1"

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

if not exist bin mkdir bin

set "CFLAGS=/nologo /O2 /MT /utf-8 /W3 /DUNICODE /D_UNICODE"
set "LIBS=winhttp.lib iphlpapi.lib wlanapi.lib user32.lib"

if /i "%MODE%"=="debug" (
    echo [2/3] Compiling console build...
    cl %CFLAGS% /DCONSOLE_BUILD c\UltraLightProbe.c /Fe:bin\probe-console.exe /Fo:bin\probe-con.obj /link /SUBSYSTEM:CONSOLE %LIBS%
    set "OUT=bin\probe-console.exe"
) else (
    echo [2/3] Compiling silent GUI build...
    cl %CFLAGS% c\UltraLightProbe.c /Fe:bin\probe.exe /Fo:bin\probe-gui.obj /link /SUBSYSTEM:WINDOWS /ENTRY:wWinMainCRTStartup %LIBS%
    set "OUT=bin\probe.exe"
)

if errorlevel 1 ( echo [ERROR] Build failed. & goto :end )

del /q bin\*.obj >nul 2>&1
echo [3/3] OK -^> %OUT%
dir %OUT% | findstr /i "probe"

:end
if not defined NOPAUSE pause
endlocal
