@echo off
REM ===================================================================
REM  Check-PdfComments.bat
REM  Wrapper around Check-PdfComments.ps1 so a PDF can be:
REM    * double-clicked / dragged onto this file (drag-drop supports
REM      multiple files at once), or
REM    * invoked from the right-click menu / Send To (see Install-*.bat).
REM  Keeps the window open so the result is readable.
REM ===================================================================
setlocal
set "SCRIPT=%~dp0Check-PdfComments.ps1"

if not exist "%SCRIPT%" (
    echo ERROR: Check-PdfComments.ps1 not found next to this .bat.
    echo Expected: "%SCRIPT%"
    pause
    exit /b 2
)

if "%~1"=="" (
    echo Drag one or more PDF files onto this file, or pass paths as arguments.
    pause
    exit /b 2
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" echo [gate PASSED - no markup found]
if "%RC%"=="1" echo [gate FAILED - do NOT file until comments are removed]
if "%RC%"=="2" echo [could not check - see messages above]
echo.
pause
exit /b %RC%
