@echo off
REM ===================================================================
REM  Install-ContextMenu.bat
REM  Adds a per-user right-click entry on PDFs:  "Check for review comments"
REM  - Per-user (HKCU): no administrator rights required.
REM  - Registered under SystemFileAssociations\.pdf so it appears no matter
REM    which app (Acrobat, Edge, ...) owns the .pdf association.
REM  On Windows 11 it lives under "Show more options" (Shift+F10 / classic menu).
REM ===================================================================
setlocal
set "BAT=%~dp0Check-PdfComments.bat"
set "KEY=HKCU\Software\Classes\SystemFileAssociations\.pdf\shell\CheckPdfComments"

if not exist "%BAT%" (
    echo ERROR: Check-PdfComments.bat not found next to this installer.
    pause
    exit /b 2
)

reg add "%KEY%" /ve /d "Check for review comments" /f
reg add "%KEY%" /v Icon /d "imageres.dll,-102" /f
reg add "%KEY%\command" /ve /d "\"%BAT%\" \"%%1\"" /f

echo.
echo Installed. Right-click a PDF (Win11: "Show more options") and choose
echo   "Check for review comments".
echo Run Uninstall-ContextMenu.bat to remove it.
pause
