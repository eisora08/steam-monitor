@echo off
title CloudRedirect - Comprobar compatibilidad
rem Ejecuta compat-watch.ps1 a mano: compara el SHA de steamclient64.dll con
rem el ultimo publicado y, solo si cambio de verdad, corre el check y publica
rem el veredicto en la rama compat de steam-monitor. Argumentos opcionales:
rem   -DryRun   solo muestra el reporte, no publica
rem   -Force    republica aunque el feed ya tenga el mismo status
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0compat-watch.ps1" %*
echo.
pause
