@echo off
chcp 65001 >nul
setlocal

REM ===== UltraLightProbe Flutter Build =====
REM Device ID strategy:
REM   Windows: detected from exe filename (probe-xxx.exe -> xxx)
REM   Android: fixed at compile time via --dart-define=device=xxx

set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
set "MODE=%~1"
set "ENTRY=-t lib\main_full.dart"

echo UltraLightProbe Flutter Build
echo =============================

if /i "%MODE%"=="" set "BUILD_ALL=1"
if /i "%MODE%"=="win" set "BUILD_WIN=1"
if /i "%MODE%"=="phone" set "BUILD_PHONE=1"
if not defined BUILD_ALL if not defined BUILD_WIN if not defined BUILD_PHONE set "BUILD_ALL=1"

REM ----- Windows ------------------------------------------
if defined BUILD_ALL set "BUILD_WIN=1"
if defined BUILD_WIN (
  echo.
  echo === [Windows] probe-notebook.exe / probe-desktop.exe ===

  call flutter clean >nul 2>&1
  call flutter build windows --release %ENTRY%
  if errorlevel 1 ( echo [ERROR] Windows build failed. & goto :end )

  mkdir "%ROOT%\deploy" 2>nul
  mkdir "%ROOT%\deploy\notebook" "%ROOT%\deploy\desktop" 2>nul

  xcopy "%ROOT%\build\windows\x64\runner\Release" "%ROOT%\deploy\notebook\" /E /I /Y >nul 2>&1
  del "%ROOT%\deploy\notebook\probe_app.exe" >nul 2>&1
  copy "%ROOT%\build\windows\x64\runner\Release\probe_app.exe" "%ROOT%\deploy\notebook\probe-notebook.exe" >nul

  xcopy "%ROOT%\build\windows\x64\runner\Release" "%ROOT%\deploy\desktop\" /E /I /Y >nul 2>&1
  del "%ROOT%\deploy\desktop\probe_app.exe" >nul 2>&1
  copy "%ROOT%\build\windows\x64\runner\Release\probe_app.exe" "%ROOT%\deploy\desktop\probe-desktop.exe" >nul

  echo OK  -^> deploy\notebook\probe-notebook.exe
  echo OK  -^> deploy\desktop\probe-desktop.exe
)

REM ----- Android ------------------------------------------
if defined BUILD_ALL set "BUILD_PHONE=1"
if defined BUILD_PHONE (
  echo.
  echo === [Android] probe-phone1.apk / probe-phone2.apk ===

  call flutter clean >nul 2>&1
  call flutter build apk --release %ENTRY% --dart-define=device=phone1
  if errorlevel 1 ( echo [ERROR] phone1 build failed. & goto :end )
  copy /Y "%ROOT%\build\app\outputs\flutter-apk\app-release.apk" "%ROOT%\probe-phone1.apk" >nul
  echo OK  -^> probe-phone1.apk

  call flutter clean >nul 2>&1
  call flutter build apk --release %ENTRY% --dart-define=device=phone2
  if errorlevel 1 ( echo [ERROR] phone2 build failed. & goto :end )
  copy /Y "%ROOT%\build\app\outputs\flutter-apk\app-release.apk" "%ROOT%\probe-phone2.apk" >nul
  echo OK  -^> probe-phone2.apk
)

echo.
echo ====== Done ======
dir "%ROOT%\deploy\notebook\probe-notebook.exe" "%ROOT%\deploy\desktop\probe-desktop.exe" "%ROOT%\probe-phone1.apk" "%ROOT%\probe-phone2.apk" 2>nul

:end
if not defined NOPAUSE pause
endlocal
