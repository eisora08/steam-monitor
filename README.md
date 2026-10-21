# steam-monitor

Feeds de compatibilidad y patrones para:

- **OpenSteamTool**: ramas espejo `pattern`, `ipc`, `protobuf` (mismo formato y
  rutas que `madoiscool/steam-monitor`).
- **CloudRedirect**: rama `compat` con el estado de compatibilidad de cada
  `steamclient64.dll`, generado por un watcher local.

## Ramas

| Rama | Contenido | Consumidor |
| --- | --- | --- |
| `main` | documentación, workflow de espejo y scripts | — |
| `pattern` | `steamclient/<sha256>.toml`, `steamui/<sha256>.toml` | OpenSteamTool |
| `ipc` | `steamclient/<sha256>.toml`, `steamui/<sha256>.toml` | OpenSteamTool |
| `protobuf` | protos/TOML de referencia | herramientas |
| `compat` | `steamclient64/<sha256>.json` + `index.json` | CloudRedirect |

`pattern`, `ipc` y `protobuf` son **espejos** de
`https://github.com/madoiscool/steam-monitor` y los actualiza
`.github/workflows/mirror.yml` cada 10 minutos. No se editan a mano.

`compat` lo publica `scripts/compat-watch.ps1` en el PC del usuario. Solo lleva
estado (no RVAs ni firmas): CloudRedirect valida todo localmente antes de
confiar en el feed.

## OpenSteamTool

Añade a tu `opensteamtool.toml`:

```toml
[remote]
url_template = [
  "https://raw.githubusercontent.com/eisora08/steam-monitor/{channel}/{component}/{sha256}.toml",
  "https://cdn.jsdelivr.net/gh/eisora08/steam-monitor@{channel}/{component}/{sha256}.toml",
  "https://raw.githubusercontent.com/madoiscool/steam-monitor/{channel}/{component}/{sha256}.toml",
]
```

`{channel}` es `pattern`, `ipc` o `protobuf`; `{component}` es `steamclient` o
`steamui`; `{sha256}` es el hash del DLL. Una lista configurada reemplaza los
mirrors por defecto de OpenSteamTool, por eso el último elemento apunta al
upstream.

## CloudRedirect

```
https://raw.githubusercontent.com/eisora08/steam-monitor/compat/steamclient64/<sha256>.json
https://cdn.jsdelivr.net/gh/eisora08/steam-monitor@compat/steamclient64/<sha256>.json
```

Estados: `full` (todos los campos críticos resueltos), `unverified` (estático
OK, sin verificación en vivo), `audit` (algún campo crítico falló) y `blocked`
(no usar). El cliente trata `audit`/`unverified`/ausente como modo auditoría y
`blocked` como cloud desactivado.

### Config del DLL

`cloud_redirect/config.json` acepta un bloque opcional. El feed solo puede
**quitar** el estado `full`; nunca aporta direcciones ni offsets.

```json
"compat_feed": {
  "enabled": true,
  "strict": false,
  "url_templates": [
    "https://raw.githubusercontent.com/eisora08/steam-monitor/compat/steamclient64/{sha256}.json"
  ]
}
```

`strict=false` (por defecto) permite arrancar si el informe local es `full`
aunque el feed no responda. `strict=true` exige cache o feed presente.
El DLL escribe su informe en `cloud_redirect/compat.json`; el watcher lo lee
para el campo `live`.

## Watcher local

Ver `scripts/README.md`. Requiere:

- PAT fine-grained con `contents: write` e `issues: write` sobre este repo.
- `cr_compat_check.exe` compilado desde CloudRedirect.
- Tarea programada al inicio de sesión y cada 15 minutos.

El PAT se guarda con DPAPI en `%LOCALAPPDATA%\CloudRedirectMonitor\pat.clixml` y
nunca se escribe en el repo ni en los logs.

## Seguridad

- Los feeds son datos no confiables: CloudRedirect valida localmente y nunca
  aplica RVAs/offsets del feed.
- No se mezcla código GPLv3 de OpenSteamTool con el MIT de CloudRedirect.
- El workflow de espejo usa `GITHUB_TOKEN`; el watcher usa un PAT limitado a
  este repositorio. No hay self-hosted runners.

## Licencia

MIT. Los datos espejados conservan su origen y formato.
