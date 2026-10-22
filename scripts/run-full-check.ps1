#requires -Version 5.1
<#
.SYNOPSIS
  Orquesta la creación del PAT, publicación de feeds compat (Stable + Beta) y validación completa.
.DESCRIPTION
  1. Genera/verifica el PAT fine-grained (set-pat.ps1).
  2. Publica la build **actual** (Stable) en la rama compat.
  3. Pide que cambies Steam a **Beta** y reinicies Steam.
  4. Publica la build **Beta** (nuevo SHA).
  5. Valida compat.json, log y que OpenSteamTool con [cloud] enabled=true funciona.
  6. (Opcional) Registra la tarea programada cada 15 min.
.NOTES
  - Debes tener permisos de admin para registrar la tarea programada (paso 6).
  - Ejecuta este script desde una consola PowerShell **como administrador** si quieres la tarea.
#>

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$configPath = Join-Path $scriptDir 'config.json'

function Write-Step {
    param([string]$Msg)
    Write-Host "`n========== $Msg ==========" -ForegroundColor Cyan
}

function Pause-ForUser {
    param([string]$Msg)
    Write-Host "`n$Msg" -ForegroundColor Yellow
    Read-Host "Presiona ENTER cuando hayas terminado"
}

# ----------------------------------------------------------
# 1. PAT
# ----------------------------------------------------------
Write-Step "1/6  Creando / verificando PAT fine-grained"
& "$scriptDir\set-pat.ps1"
Write-Host "✅ PAT guardado en %LOCALAPPDATA%\CloudRedirectMonitor\pat.clixml" -ForegroundColor Green

# ----------------------------------------------------------
# 2. Publicar build actual (Stable)
# ----------------------------------------------------------
Write-Step "2/6  Publicando feed compat para la build **actual (Stable)**"
& "$scriptDir\compat-watch.ps1" -Config $configPath
Write-Host "✅ Feed Stable publicado" -ForegroundColor Green

# ----------------------------------------------------------
# 3. Cambiar a Steam Beta
# ----------------------------------------------------------
Write-Step "3/6  Cambia Steam a la rama **Beta**"
Write-Host @"
Instrucciones:
  1. Abre Steam → Configuración → Cuenta → Participación beta
  2. Selecciona "Steam Beta Update" en el desplegable
  3. Acepta y Steam se reiniciará descargando el nuevo steamclient64.dll
"@
Pause-ForUser "Cuando Steam haya terminado de actualizarse y esté corriendo en Beta, pulsa ENTER."

# ----------------------------------------------------------
# 4. Publicar build Beta
# ----------------------------------------------------------
Write-Step "4/6  Publicando feed compat para la **nueva build Beta**"
& "$scriptDir\compat-watch.ps1" -Config $configPath
Write-Host "✅ Feed Beta publicado" -ForegroundColor Green

# ----------------------------------------------------------
# 5. Validación completa
# ----------------------------------------------------------
Write-Step "5/6  Validación post-Beta"

$steamDir = "C:\Program Files (x86)\Steam Luma"
$compatJson = Join-Path $steamDir 'cloud_redirect\compat.json'
$logFile    = Join-Path $steamDir 'cloud_redirect.log'

if (Test-Path $compatJson) {
    $j = Get-Content $compatJson -Raw | ConvertFrom-Json
    Write-Host "compat.json → SHA: $($j.steamclient_sha256.Substring(0,12))  status: $($j.status)  allowlisted: $($j.allowlisted)"
    Write-Host "Subsystems: cloud=$($j.subsystems.cloud) manifest=$($j.subsystems.manifest) playtime=$($j.subsystems.playtime) kv=$($j.subsystems.kv)"
    if ($j.status -eq 'full' -and $j.allowlisted) {
        Write-Host "✅ compat.json OK" -ForegroundColor Green
    } else {
        Write-Warning "⚠ compat.json no muestra full/allowlisted"
    }
} else {
    Write-Warning "compat.json no encontrado en $compatJson"
}

if (Test-Path $logFile) {
    $lastCompat = Select-String -Path $logFile -Pattern '\[Compat\]' | Select-Object -Last 1
    if ($lastCompat) {
        Write-Host "Última línea [Compat] en log:"
        Write-Host "  $($lastCompat.Line.Trim())"
        if ($lastCompat.Line -match 'status=full' -and $lastCompat.Line -match 'cloud=1') {
            Write-Host "✅ Log OK" -ForegroundColor Green
        } else {
            Write-Warning "⚠ Log no muestra status=full cloud=1"
        }
    }
}

Write-Host @"
Ahora abre **OpenSteamTool** con la configuración:
  [cloud]
  enabled = true
  library = "cloud_redirect.dll"

y verifica:
  • Hooks → ACTIVE (busca "All hooks ACTIVE" en el log)
  • Juego con AutoCloud → sube/baja blobs (crea save, cierra, abre)
  • Borra un save → aparece en cloud_redirect\trash\
"@
Pause-ForUser "Cuando hayas confirmado que todo funciona, pulsa ENTER."

# ----------------------------------------------------------
# 6. Tarea programada (opcional)
# ----------------------------------------------------------
Write-Step "6/6  ¿Registrar tarea programada cada 15 min? (s/n)"
$ans = Read-Host "Escribe 's' para sí, cualquier otra tecla para omitir"
if ($ans -ieq 's') {
    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptDir\compat-watch.ps1`" -Config `"$configPath`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $trigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
        -RepetitionInterval (New-TimeSpan -Minutes 15) `
        -RepetitionDuration ([TimeSpan]::MaxValue)).Repetition
    Register-ScheduledTask -TaskName "CloudRedirect compat watcher" `
        -Action $action -Trigger $trigger -RunLevel Limited -Force -ErrorAction Stop
    Write-Host "✅ Tarea programada registrada" -ForegroundColor Green
} else {
    Write-Host "⏭ Tarea programada omitida. Ejecuta manualmente .\compat-watch.ps1 cuando Steam se actualice." -ForegroundColor Yellow
}

Write-Host "`n🎉  Todo completado. El feed compat está al día para Stable y Beta." -ForegroundColor Cyan