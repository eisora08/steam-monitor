#requires -Version 5.1
<#
.SYNOPSIS
  Publica el estado de compatibilidad de steamclient64.dll en la rama compat.
.DESCRIPTION
  Se ejecuta en el PC del usuario. No ejecuta codigo del repositorio: solo
  llama a cr_compat_check.exe, lee el informe en vivo de CloudRedirect y
  publica JSON por la API de GitHub con un PAT fine-grained.
.PARAMETER Config
  Ruta a config.json (por defecto, junto al script).
.PARAMETER DryRun
  Imprime el JSON y no publica nada.
.PARAMETER Force
  Ignora el state.json y vuelve a comprobar el mismo hash.
#>
[CmdletBinding()]
param(
    [string]$Config = '',
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
if (-not $Config) { $Config = Join-Path $PSScriptRoot 'config.json' }
$script:UtcNow = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "$script:UtcNow [$Level] $Message"
    Write-Host $line
    if ($script:LogFile) {
        try {
            $dir = Split-Path -Parent $script:LogFile
            if ($dir -and -not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Force -Path $dir | Out-Null
            }
            Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
        } catch { }
    }
}

function Expand-Path([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    return [Environment]::ExpandEnvironmentVariables($Path)
}

function Read-Json([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return $raw | ConvertFrom-Json
}

function Write-Json([string]$Path, $Value) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $json = $Value | ConvertTo-Json -Depth 20
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $utf8)
}

function Get-Pat {
    if ($env:CR_MONITOR_PAT) { return $env:CR_MONITOR_PAT }
    $file = Expand-Path $script:Cfg.pat_file
    if (-not (Test-Path -LiteralPath $file)) {
        throw "PAT no encontrado en $file. Guarda un PSCredential con Export-Clixml o define CR_MONITOR_PAT."
    }
    $cred = Import-Clixml -LiteralPath $file
    if ($cred -is [System.Management.Automation.PSCredential]) {
        return $cred.GetNetworkCredential().Password
    }
    if ($cred -is [string]) { return $cred }
    throw "Formato de PAT no reconocido en $file"
}

function Get-SteamPath {
    if ($script:Cfg.steam_path) {
        $p = Expand-Path $script:Cfg.steam_path
        if (Test-Path -LiteralPath (Join-Path $p 'steamclient64.dll')) { return $p }
    }
    foreach ($reg in @(
        @{ Path = 'HKCU:\Software\Valve\Steam'; Name = 'SteamPath' },
        @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam'; Name = 'InstallPath' },
        @{ Path = 'HKLM:\SOFTWARE\Valve\Steam'; Name = 'InstallPath' }
    )) {
        try {
            $v = (Get-ItemProperty -LiteralPath $reg.Path -ErrorAction Stop).($reg.Name)
            if ($v -and (Test-Path -LiteralPath (Join-Path $v 'steamclient64.dll'))) { return $v }
        } catch { }
    }
    foreach ($fallback in @(
        'C:\Program Files (x86)\Steam',
        'C:\Program Files\Steam'
    )) {
        if (Test-Path -LiteralPath (Join-Path $fallback 'steamclient64.dll')) { return $fallback }
    }
    throw 'No se pudo localizar steamclient64.dll (config.steam_path).'
}

function Get-SteamChannel {
    try {
        $beta = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).BetaKey
        if ($beta) { return 'beta' }
    } catch { }
    return 'stable'
}

function Get-SteamVersion([string]$SteamPath, [string]$Channel) {
    $names = if ($Channel -eq 'beta') {
        @('steam_client_publicbeta_win64.manifest', 'steam_client_win64.manifest')
    } else {
        @('steam_client_win64.manifest')
    }
    foreach ($name in $names) {
        $path = Join-Path $SteamPath (Join-Path 'package' $name)
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        $m = [regex]::Match($raw, '"version"\s+"(\d+)"')
        if ($m.Success) { return [int64]$m.Groups[1].Value }
    }
    return 0
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Invoke-CompatCheck([string]$Exe, [string]$Dll, [string]$Channel, [int64]$Version) {
    if (-not (Test-Path -LiteralPath $Exe)) {
        throw "cr_compat_check.exe no encontrado: $Exe"
    }
    $id = [Guid]::NewGuid().ToString('N')
    $out = Join-Path $env:TEMP ("cr_compat_$id.json")
    $stdout = Join-Path $env:TEMP ("cr_compat_$id.out")
    $stderr = Join-Path $env:TEMP ("cr_compat_$id.err")
    try {
        $arguments = "--dll `"$Dll`" --out `"$out`" --channel $Channel --version $Version"
        $proc = Start-Process -FilePath $Exe -ArgumentList $arguments -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $code = $proc.ExitCode
        if (-not (Test-Path -LiteralPath $out)) {
            $detail = ''
            if (Test-Path -LiteralPath $stderr) {
                $detail = (Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue).Trim()
            }
            throw "cr_compat_check no genero $out (exit $code): $detail"
        }
        $report = Read-Json $out
        if (-not $report) { throw "cr_compat_check genero un JSON vacio (exit $code)" }
        return $report
    } finally {
        foreach ($path in @($out, $stdout, $stderr)) {
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Get-GitHubHeaders([string]$Pat) {
    return @{
        Authorization          = "Bearer $Pat"
        Accept                 = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent'           = 'CloudRedirectMonitor/1.0'
    }
}

function Get-GitHubFile([string]$Path, $Headers) {
    $uri = "https://api.github.com/repos/$($script:Cfg.feed_repo)/contents/$Path" + "?ref=$($script:Cfg.branch)"
    try {
        $r = Invoke-RestMethod -Uri $uri -Headers $Headers -Method Get -TimeoutSec 20
        $text = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($r.content -replace '\s', '')))
        return @{ sha = $r.sha; json = ($text | ConvertFrom-Json); text = $text }
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        if ($code -eq 404) { return $null }
        throw
    }
}

function Publish-GitHubFile([string]$Path, [string]$Text, [string]$Message, $Headers) {
    $uri = "https://api.github.com/repos/$($script:Cfg.feed_repo)/contents/$Path"
    $body = @{
        message = $Message
        content = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Text))
        branch  = $script:Cfg.branch
    }
    $existing = Get-GitHubFile $Path $Headers
    if ($existing -and $existing.sha) { $body.sha = $existing.sha }
    $json = $body | ConvertTo-Json -Depth 5
    Invoke-RestMethod -Uri $uri -Headers $Headers -Method Put -Body $json `
        -ContentType 'application/json' -TimeoutSec 30 | Out-Null
}

function Test-RawFile([string]$Url) {
    try {
        $r = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -TimeoutSec 10
        return ($r.StatusCode -eq 200)
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        if ($code -eq 404) { return $false }
        return $null
    }
}

function Update-Issue([string]$Sha, [string]$Channel, [int64]$Version, [string]$Status, $Report, $Headers) {
    $short = $Sha.Substring(0, 7)
    $title = "compat: $short $Channel $Version $Status"
    $label = ($script:Cfg.issue_labels | Select-Object -First 1)
    $search = "repo:$($script:Cfg.feed_repo) is:issue is:open label:$label in:title $short"
    $found = $null
    try {
        $res = Invoke-RestMethod -Uri ("https://api.github.com/search/issues?q=" + [uri]::EscapeDataString($search)) `
            -Headers $Headers -Method Get -TimeoutSec 20
        $found = $res.items | Select-Object -First 1
    } catch { }

    if ($Status -eq 'full') {
        if ($found) {
            $body = @{ state = 'closed'; body = "Resuelto: ``$Status`` para ``$Sha`` ($Channel $Version)." } |
                ConvertTo-Json -Depth 5
            Invoke-RestMethod -Uri $found.url -Headers $Headers -Method Patch -Body $body `
                -ContentType 'application/json' -TimeoutSec 20 | Out-Null
        }
        return
    }

    $failed = @()
    if ($Report.fields) {
        foreach ($p in $Report.fields.PSObject.Properties) {
            if ($p.Value.ok -eq $false) { $failed += "- ``$($p.Name)`` ($($p.Value.kind))" }
        }
    }
    $reasons = @()
    if ($Report.reasons) { $reasons = $Report.reasons }
    $bodyText = @(
        "Build: ``$Sha``",
        "Canal: ``$Channel``",
        "Version: ``$Version``",
        "Estado: ``$Status``",
        "",
        "Campos fallidos:",
        $(if ($failed.Count) { $failed -join "`n" } else { '- (ninguno)' }),
        "",
        "Razones:",
        $(if ($reasons.Count) { ($reasons | ForEach-Object { "- $_" }) -join "`n" } else { '- (ninguna)' })
    ) -join "`n"

    if ($found) {
        $body = @{ title = $title; body = $bodyText } | ConvertTo-Json -Depth 5
        Invoke-RestMethod -Uri $found.url -Headers $Headers -Method Patch -Body $body `
            -ContentType 'application/json' -TimeoutSec 20 | Out-Null
    } else {
        $payload = @{ title = $title; body = $bodyText; labels = $script:Cfg.issue_labels } |
            ConvertTo-Json -Depth 5
        Invoke-RestMethod -Uri "https://api.github.com/repos/$($script:Cfg.feed_repo)/issues" `
            -Headers $Headers -Method Post -Body $payload -ContentType 'application/json' -TimeoutSec 20 | Out-Null
    }
}

function Update-Index([string]$Sha, [string]$Channel, [int64]$Version, [string]$Status, $Report, $Headers) {
    $existing = Get-GitHubFile 'index.json' $Headers
    if ($existing -and $existing.json) { $index = $existing.json } else {
        $index = [pscustomobject]@{ schema = 1; builds = @(); latest = [pscustomobject]@{}; osl = [pscustomobject]@{} }
    }
    if (-not $index.builds) { $index | Add-Member -NotePropertyName builds -NotePropertyValue @() -Force }
    if (-not $index.latest) { $index | Add-Member -NotePropertyName latest -NotePropertyValue ([pscustomobject]@{}) -Force }
    if (-not $index.osl) { $index | Add-Member -NotePropertyName osl -NotePropertyValue ([pscustomobject]@{}) -Force }

    $entry = [pscustomobject]@{
        sha256        = $Sha
        channel       = $Channel
        steam_version = $Version
        status        = $Status
        tested_at     = $script:UtcNow
        osl           = $index.osl
    }
    $builds = @($index.builds | Where-Object { $_.sha256 -ne $Sha })
    $index.builds = @($entry) + $builds | Select-Object -First 50
    $index | Add-Member -NotePropertyName updated_at -NotePropertyValue $script:UtcNow -Force
    $index.latest | Add-Member -NotePropertyName $Channel -NotePropertyValue ([pscustomobject]@{
        sha256 = $Sha; steam_version = $Version; status = $Status; tested_at = $script:UtcNow
    }) -Force

    $text = $index | ConvertTo-Json -Depth 20
    Publish-GitHubFile 'index.json' $text "index: $Channel $Version $($Sha.Substring(0,7)) $Status" $Headers
}

# ---------------------------------------------------------------- main

if (-not (Test-Path -LiteralPath $Config)) {
    throw "No existe $Config. Copia config.example.json y ajusta los valores."
}
$script:Cfg = Read-Json $Config
if (-not $script:Cfg) { throw "Config vacia: $Config" }
if (-not $script:Cfg.feed_repo) { throw 'config.feed_repo es obligatorio' }
if (-not $script:Cfg.branch) { $script:Cfg.branch = 'compat' }
if (-not $script:Cfg.issue_labels) { $script:Cfg.issue_labels = @('compat') } else { $script:Cfg.issue_labels = @($script:Cfg.issue_labels) }
$script:LogFile = Expand-Path $script:Cfg.log_file
if (-not $script:LogFile) { $script:LogFile = Join-Path $env:LOCALAPPDATA 'CloudRedirectMonitor\watch.log' }

try {
    $steamPath = Get-SteamPath
    $dll = Join-Path $steamPath 'steamclient64.dll'
    $channel = Get-SteamChannel
    $version = Get-SteamVersion $steamPath $channel
    $sha = Get-Sha256 $dll
    Write-Log "Steam=$steamPath channel=$channel version=$version sha=$sha"

    $statePath = Expand-Path $script:Cfg.state_file
    if (-not $statePath) { $statePath = Join-Path $env:LOCALAPPDATA 'CloudRedirectMonitor\state.json' }
    $state = Read-Json $statePath
    if (-not $Force -and $state -and $state.sha256 -eq $sha) {
        Write-Log 'Hash sin cambios; nada que publicar.'
        exit 0
    }

    $check = Invoke-CompatCheck (Expand-Path $script:Cfg.check_exe) $dll $channel $version
    $live = Read-Json (Join-Path $steamPath 'cloud_redirect\compat.json')
    $liveOk = $false
    $liveAvailable = $false
    $liveDetail = 'sin informe en vivo'
    if ($live -and $live.steamclient_sha256 -eq $sha -and $live.live) {
        $liveAvailable = [bool]$live.live.available
        $liveOk = [bool]$live.live.ok
        if ($live.live.detail) { $liveDetail = [string]$live.live.detail }
    }

    $status = 'audit'
    if ($check.status -eq 'full' -and $liveOk) {
        $status = 'full'
    } elseif ($check.status -eq 'full' -and $script:Cfg.allow_unverified) {
        $status = 'full'
        $liveDetail = 'estatico OK; sin verificacion en vivo (allow_unverified)'
    } elseif ($check.status -eq 'full') {
        $status = 'unverified'
    }

    $report = $check
    $report | Add-Member -NotePropertyName channel -NotePropertyValue $channel -Force
    $report | Add-Member -NotePropertyName steam_version -NotePropertyValue $version -Force
    $report | Add-Member -NotePropertyName tested_at -NotePropertyValue $script:UtcNow -Force
    $report | Add-Member -NotePropertyName status -NotePropertyValue $status -Force
    $report | Add-Member -NotePropertyName live -NotePropertyValue ([pscustomobject]@{
        ok = $liveOk; available = $liveAvailable; detail = $liveDetail
    }) -Force

    $json = $report | ConvertTo-Json -Depth 20
    if ($DryRun) {
        Write-Host $json
        exit 0
    }

    $pat = Get-Pat
    $headers = Get-GitHubHeaders $pat

    $branchUri = "https://api.github.com/repos/$($script:Cfg.feed_repo)/branches/$($script:Cfg.branch)"
    try {
        Invoke-RestMethod -Uri $branchUri -Headers $headers -Method Get -TimeoutSec 20 | Out-Null
    } catch {
        throw "La rama '$($script:Cfg.branch)' no existe en $($script:Cfg.feed_repo). Crea la rama compat primero."
    }

    $osl = [pscustomobject]@{
        pattern  = Test-RawFile "https://raw.githubusercontent.com/$($script:Cfg.feed_repo)/pattern/steamclient/$sha.toml"
        ipc      = Test-RawFile "https://raw.githubusercontent.com/$($script:Cfg.feed_repo)/ipc/steamclient/$sha.toml"
        protobuf = Test-RawFile "https://raw.githubusercontent.com/$($script:Cfg.feed_repo)/protobuf/steamclient/$sha.toml"
    }

    Publish-GitHubFile "steamclient64/$sha.json" $json "compat: $channel $version $($sha.Substring(0,7)) $status" $headers
    Update-Index $sha $channel $version $status $report $headers
    Update-Issue $sha $channel $version $status $report $headers

    Write-Json $statePath ([pscustomobject]@{
        sha256 = $sha; status = $status; checked_at = $script:UtcNow
    })
    Write-Log "Publicado: status=$status liveOk=$liveOk liveAvailable=$liveAvailable"
    exit 0
} catch {
    Write-Log $_.Exception.Message 'ERROR'
    exit 1
}
