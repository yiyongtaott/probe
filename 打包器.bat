@echo off
:: 【修复乱码】强制控制台使用 UTF-8 编码
chcp 65001 >nul

echo ===== Spring Boot Native Image 构建脚本 =====
echo 使用你的 VS 路径: D:\aMyDrivesF\develop\VS
echo.

REM 1. 首先设置 Visual Studio 环境
echo [1/4] 设置 Visual Studio 环境...
set VS_ROOT=D:\aMyDrivesF\develop\VS

REM 检查 VS 版本和路径
if exist "%VS_ROOT%\VC\Auxiliary\Build\vcvars64.bat" (
    echo 找到 vcvars64.bat: %VS_ROOT%\VC\Auxiliary\Build\vcvars64.bat
    call "%VS_ROOT%\VC\Auxiliary\Build\vcvars64.bat"
    echo ✓ Visual Studio 环境已设置
) else (
    echo 错误: 在 %VS_ROOT% 中未找到 vcvars64.bat
    echo.
    echo 正在搜索其他可能的路径...
    
    REM 搜索可能的子目录
    for /d %%i in ("%VS_ROOT%\*") do (
        if exist "%%i\VC\Auxiliary\Build\vcvars64.bat" (
            echo 找到: %%i\VC\Auxiliary\Build\vcvars64.bat
            call "%%i\VC\Auxiliary\Build\vcvars64.bat"
            set VS_ROOT=%%i
            echo ✓ 使用 VS 路径: %%i
            goto :vs_found
        )
    )
    
    echo.
    echo 未找到 vcvars64.bat！请检查：
    echo 1. VS 是否正确安装
    echo 2. 是否安装了 C++ 开发工具
    echo 3. 路径是否正确
    echo.
    goto :error_exit
)

:vs_found
echo.

REM 2. 【终极修复】直接锁定你系统配置好的 JAVA_HOME
echo [2/4] 设置 Java 环境...

:: 如果你系统里有 JAVA_HOME，直接使用它，并强行将其刷新到 PATH 最前面
if defined JAVA_HOME (
    set "GRAALVM_HOME=%JAVA_HOME%"
    set "PATH=%JAVA_HOME%\bin;%PATH%"
) else (
    echo ✗ 错误: 未检测到系统的 JAVA_HOME 环境变量！
    echo 请检查系统环境变量是否配置正确。
    goto :error_exit
)

echo ✓ Java 环境已成功载入
echo   JAVA_HOME: %JAVA_HOME%
echo.

REM 3. 验证环境
echo [3/4] 验证编译环境...
where cl.exe >nul
if errorlevel 1 (
    echo ✗ 错误: cl.exe 未找到！
    echo  Visual Studio 环境设置可能失败
    echo  当前 PATH 中的相关路径:
    echo %PATH% | findstr /i "msvc\|visual studio\|vc\tools"
    goto :error_exit
) else (
    echo ✓ cl.exe 找到
    where cl.exe
)

where link.exe >nul
if errorlevel 1 (
    echo ✗ 警告: link.exe 未找到
) else (
    echo ✓ link.exe 找到
)

where native-image.cmd >nul
if errorlevel 1 (
    echo ✗ 错误: native-image 未找到！
    echo  请检查 GraalVM 安装是否完整（确保它包含 Native Image 组件）
    goto :error_exit
) else (
    echo ✓ native-image 找到
)

echo.
echo 环境检查完成！
echo.

REM 4. 开始构建
echo [4/4] 构建 Native Image...
echo 切换到项目目录...
cd /d D:\aMyDrivesF\develop\java-project\demo\probe
echo 当前目录: %cd%
echo.

echo 这可能需要几分钟，请耐心等待...
echo ========================================
call mvn -Pnative clean native:compile -DskipTests

if errorlevel 1 (
    echo.
    echo ========================================
    echo 构建失败！
    echo.
    echo 常见原因:
    echo 1. Visual Studio 版本太旧（需要 2022 17.1.0+）
    echo 2. 缺少 Windows SDK
    echo 3. 内存不足（尝试关闭其他程序）
    echo 4. 网络问题（需要下载依赖）
    echo.
    echo 建议:
    echo 1. 检查 VS 安装：确保安装了 "使用 C++ 的桌面开发"
    echo 2. 或使用 Docker 构建（无需 VS）
    echo.
    goto :error_exit
)

echo.
echo ========================================
echo ===== 构建成功！ =====
echo.

REM 5. 检查结果
:: 开启延迟变量绑定，确保能够在 if 语句内正确显示文件大小
setlocal enabledelayedexpansion
if exist "target\probe.exe" (
    for %%F in ("target\probe.exe") do (
        set /a size_kb=%%~zF / 1024
        set /a size_mb=%%~zF / 1024 / 1024
        echo 生成: target\probe.exe
        echo 大小: !size_mb! MB (!size_kb! KB)
        echo.
    )
    
    echo 文件信息:
    dir target\probe.exe
    
    echo.
    set /p RUN=是否立即运行程序？(y/n): 
    if /i "!RUN!"=="y" (
        echo.
        echo 启动应用（按 Ctrl+C 停止）...
        echo 等待 3 秒...
        timeout /t 3 /nobreak >nul
        start target\probe.exe
        echo 应用已启动！
    )
) else (
    echo 警告: 未找到 probe.exe
    echo target 目录内容:
    dir target
)
endlocal

echo.
echo ========================================
echo 完成！
pause
exit /b 0

:: 【修复闪退】统一的错误退出拦截点
:error_exit
echo.
echo ----------------------------------------
echo 脚本因错误提前终止。
pause
exit /b 1