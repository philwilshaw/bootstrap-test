@echo off
setlocal EnableExtensions
title Bootstrap New GCP Project

rem ============================================================
rem  Portable launcher — drop this .bat into ANY new project
rem  folder (empty or not), double-click, and it bootstraps
rem  GCP + GitHub + Cloud Run for that folder.
rem
rem  Needs: gcloud, git, gh (for GitHub steps), Cursor optional
rem ============================================================

set "ROOT=%~dp0"
rem Strip trailing backslash for nicer paths
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
cd /d "%ROOT%"

set "SCRIPT=%ROOT%\scripts\bootstrap-new-project.ps1"
set "SCRIPT_URL=https://raw.githubusercontent.com/philwilshaw/bedtime/dev/scripts/bootstrap-new-project.ps1"

echo.
echo  Project folder: %ROOT%
echo.

rem Ensure bootstrap script exists next to this bat (download if needed)
if not exist "%SCRIPT%" (
  echo  Bootstrap script not found locally — downloading template...
  if not exist "%ROOT%\scripts" mkdir "%ROOT%\scripts"
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
    "try { Invoke-WebRequest -UseBasicParsing -Uri '%SCRIPT_URL%' -OutFile '%SCRIPT%'; Write-Host '  Downloaded scripts\bootstrap-new-project.ps1' } catch { Write-Host '  ERROR: Could not download bootstrap script.'; Write-Host '  Copy scripts\bootstrap-new-project.ps1 into this folder and retry.'; Write-Host '  $_'; exit 1 }"
  if errorlevel 1 (
    echo.
    pause
    exit /b 1
  )
  echo.
)

rem Open Cursor on THIS folder (wherever you dropped the bat)
echo  Opening Cursor on this folder...
where cursor >nul 2>&1
if %ERRORLEVEL%==0 (
  start "" cursor "%ROOT%"
) else if exist "%LOCALAPPDATA%\Programs\cursor\Cursor.exe" (
  start "" "%LOCALAPPDATA%\Programs\cursor\Cursor.exe" "%ROOT%"
) else if exist "%LOCALAPPDATA%\Programs\cursor\resources\app\bin\cursor.cmd" (
  start "" "%LOCALAPPDATA%\Programs\cursor\resources\app\bin\cursor.cmd" "%ROOT%"
) else (
  echo  WARNING: Cursor not found — continuing without opening the IDE.
)
echo.

echo  Starting bootstrap. Answer prompts once, type YES, then let it run.
echo  Script: %SCRIPT%
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -SourceDir "%ROOT%"
set "EXITCODE=%ERRORLEVEL%"

echo.
if "%EXITCODE%"=="0" (
  echo  Bootstrap finished successfully.
) else (
  echo  Bootstrap exited with code %EXITCODE%.
)
echo.
pause
exit /b %EXITCODE%
