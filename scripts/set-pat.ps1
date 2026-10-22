#requires -Version 5.1
<#
.SYNOPSIS
  Guarda el PAT fine-grained del watcher con DPAPI y ACL de usuario.
.DESCRIPTION
  Pide el token de forma oculta, comprueba que GitHub lo acepta y que el
  repositorio es accesible, y lo escribe como PSCredential exportado con
  Export-Clixml. El archivo queda ligado al usuario de Windows actual y solo
  ese usuario puede leerlo.
.PARAMETER Path
  Destino del .clixml. Por defecto %LOCALAPPDATA%\CloudRedirectMonitor\pat.clixml.
.PARAMETER Repo
  Repositorio que debe poder leer el token (owner/name).
#>
[CmdletBinding()]
param(
    [string]$Path = (Join-Path $env:LOCALAPPDATA 'CloudRedirectMonitor\pat.clixml'),
    [string]$Repo = 'eisora08/steam-monitor'
)

$ErrorActionPreference = 'Stop'

$dir = Split-Path -Parent $Path
if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}

$secure = Read-Host -AsSecureString -Prompt 'PAT fine-grained (no se muestra)'
if (-not $secure -or $secure.Length -eq 0) {
    throw 'No se introdujo ningún PAT.'
}

$cred = [System.Management.Automation.PSCredential]::new('pat', $secure)
$pat = $cred.GetNetworkCredential().Password
if ([string]::IsNullOrWhiteSpace($pat)) {
    throw 'El PAT está vacío.'
}

$headers = @{
    Authorization          = "Bearer $pat"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'           = 'CloudRedirectMonitor/1.0'
}

try {
    $user = Invoke-RestMethod -Uri 'https://api.github.com/user' -Headers $headers `
        -Method Get -TimeoutSec 20
    $repoInfo = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo" -Headers $headers `
        -Method Get -TimeoutSec 20
} catch {
    throw "GitHub rechazó el PAT o no puede leer '$Repo': $($_.Exception.Message)"
}

if (-not $repoInfo.permissions.push) {
    throw "El PAT puede leer '$Repo' pero no tiene Contents: Read and write (push=$($repoInfo.permissions.push))."
}

$cred | Export-Clixml -LiteralPath $Path -Depth 2

# Export-Clixml protege el secreto con DPAPI, pero el archivo puede heredar
# ACLs amplias de la carpeta. Deja solo al usuario actual.
try {
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $me, 'FullControl', 'Allow')
    $acl.SetAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $acl
} catch {
    Write-Warning ("No se pudo restringir la ACL de {0}: {1}" -f $Path, $_.Exception.Message)
}

Write-Host "PAT válido para $($user.login); guardado en $Path"
Write-Host "Repo: $($repoInfo.full_name); push=$($repoInfo.permissions.push)"
