@echo off
setlocal

:: ============================================================
:: FS25 Vehicle Sync - Release Archive Builder
:: Runs the tests, then builds dist\FS25_VehicleSync.zip
:: ============================================================

set SCRIPT_DIR=%~dp0
set SCRIPT_DIR=%SCRIPT_DIR:~0,-1%
set OUTPUT_PATH=%SCRIPT_DIR%\dist\FS25_VehicleSync.zip

pushd "%SCRIPT_DIR%"
"C:\Program Files (x86)\Lua\5.1\lua.exe" tests\run_tests.lua --coverage
if errorlevel 1 (
    echo.
    echo ERROR: tests failed, no archive built.
    popd
    exit /b 1
)
popd

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%\create_release.ps1" -Src "%SCRIPT_DIR%" -Dst "%OUTPUT_PATH%"

if exist "%OUTPUT_PATH%" (
    echo.
    echo SUCCESS: %OUTPUT_PATH%
) else (
    echo.
    echo ERROR: Archive was not created.
    exit /b 1
)
