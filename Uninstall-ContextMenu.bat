@echo off
REM Removes the "Check for review comments" right-click entry (per-user).
setlocal
set "KEY=HKCU\Software\Classes\SystemFileAssociations\.pdf\shell\CheckPdfComments"
reg delete "%KEY%" /f
echo.
echo Removed (if it was present).
pause
