@echo off
REM ===================================================================
REM  commandos-1080p-fix - launcher
REM
REM  Double-click this file, pick a game, and it does the rest.
REM  Close the game first - the scripts rewrite files inside its folder.
REM ===================================================================

setlocal
cd /d "%~dp0"

:menu
cls
echo.
echo   ================================================================
echo    Commandos 1080p fix
echo   ================================================================
echo.
echo    1  -  Commandos: Behind Enemy Lines
echo    2  -  Commandos: Beyond the Call of Duty
echo    3  -  both
echo.
echo    4  -  UNDO on Behind Enemy Lines
echo    5  -  UNDO on Beyond the Call of Duty
echo.
echo    0  -  quit
echo.
set "choice="
set /p choice="   Your choice: "

if "%choice%"=="1" goto bel
if "%choice%"=="2" goto bcd
if "%choice%"=="3" goto both
if "%choice%"=="4" goto belundo
if "%choice%"=="5" goto bcdundo
if "%choice%"=="0" exit /b 0
goto menu

:bel
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Fix-BehindEnemyLines.ps1"
goto done

:bcd
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Fix-BeyondTheCallOfDuty.ps1"
goto done

:both
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Fix-BehindEnemyLines.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Fix-BeyondTheCallOfDuty.ps1"
goto done

:belundo
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Fix-BehindEnemyLines.ps1" -Uninstall
goto done

:bcdundo
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Fix-BeyondTheCallOfDuty.ps1" -Uninstall
goto done

:done
echo.
pause
goto menu
