@echo off
chcp 65001 >nul
cd /d "%~dp0"
where pwsh.exe >nul 2>nul
if %errorlevel%==0 (
    start "换号器" /min pwsh.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0换号器.ps1"
) else (
    start "换号器" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0换号器.ps1"
)
