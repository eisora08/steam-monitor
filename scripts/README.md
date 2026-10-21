# Watcher local

Publica el estado de compatibilidad de la build de Steam instalada en
`compat/steamclient64/<sha256>.json` y actualiza `compat/index.json`.

## 1. PAT

Crea un PAT fine-grained en GitHub:

- Repository access: solo `eisora08/steam-monitor`.
- Permissions: `Contents: Read and write`, `Issues: Read and write`.

Guárdalo con DPAPI (solo tu usuario puede descifrarlo):

```powershell
$dir = "$env:LOCALAPPDATA\CloudRedirectMonitor"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$cred = Get-Credential -UserName "pat" -Message "Pega el PAT fine-grained"
$cred | Export-Clixml "$dir\pat.clixml"
```

Alternativa para pruebas: variable de entorno `CR_MONITOR_PAT`.

## 2. Config

Compila `cr_compat_check.exe` desde CloudRedirect:

```powershell
cmake --build <build> --config Release --target cr_compat_check
Copy-Item <build>\Release\cr_compat_check.exe "$env:LOCALAPPDATA\CloudRedirectMonitor\" -Force
```

```powershell
Copy-Item .\config.example.json .\config.json
notepad .\config.json
```

Ajusta `check_exe` a tu `cr_compat_check.exe` y deja `allow_unverified` en
`true` hasta que el DLL publique un informe en vivo completo. Cuando el feed
esté estable, ponlo en `false` para exigir `live.ok`.

## 3. Prueba

```powershell
.\compat-watch.ps1 -Config .\config.json -DryRun
```

Si el JSON es correcto, publica:

```powershell
.\compat-watch.ps1 -Config .\config.json
```

## 4. Tarea programada

```powershell
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
  -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\ruta\al\steam-monitor\scripts\compat-watch.ps1" -Config "C:\ruta\al\steam-monitor\scripts\config.json"'
$trigger = New-ScheduledTaskTrigger -AtLogOn
$trigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
  -RepetitionInterval (New-TimeSpan -Minutes 15) `
  -RepetitionDuration ([TimeSpan]::MaxValue)).Repetition
Register-ScheduledTask -TaskName "CloudRedirect compat watcher" `
  -Action $action -Trigger $trigger -RunLevel Limited -Force
```

El script es idempotente: si el hash no cambió desde `state.json`, sale sin
publicar. Usa `-Force` para reprocesar el mismo hash.

## Estados

| Estado | Significado |
| --- | --- |
| `full` | Todos los campos críticos resueltos; el cliente puede escribir. |
| `unverified` | Estático OK, sin verificación en vivo; el cliente audita. |
| `audit` | Algún campo crítico falló; el cliente no escribe. |
| `blocked` | No usar esta build. |

## Notas

- El script no ejecuta código del repo; solo `cr_compat_check.exe` local.
- No subas `config.json`, `pat.clixml`, `state.json` ni logs.
- Si el PC está apagado no se publica nada; el cliente usa cache y su política
  estricta.
