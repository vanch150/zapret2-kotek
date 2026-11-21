@echo off
chcp 65001 > nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0pack_for_ai.ps1"
if errorlevel 1 pause
