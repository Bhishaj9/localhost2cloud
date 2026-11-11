<#
.SYNOPSIS
    Install the two tools the localhost2cloud skill needs.

.DESCRIPTION
    Ensures cloudflared (the tunnel) and caddy (the single-origin gateway) are
    available, preferring winget and falling back to direct downloads into
    D:\Tools. Safe to re-run; skips anything already installed.

.PARAMETER ToolsDir
    Where direct downloads go. Default: D:\Tools

.PARAMETER SkipWinget
    Force the download path even if winget is present.

.EXAMPLE
    .\Install-Tools.ps1
#>
[CmdletBinding()]
param(
    [string]$ToolsDir = 'D:\Tools',
    [switch]$SkipWinget
)

. (Join-Path $PSScriptRoot 'common.ps1')

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Test-Installed {
    param([string]$Name, [string]$Dir)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $exe = Join-Path $Dir "$Name.exe"
    if (Test-Path $exe) { return $exe }
    return $null
}

Write-Step "cloudflared"
$existing = Test-Installed -Name 'cloudflared' -Dir (Join-Path $ToolsDir 'cloudflared')
if ($existing) {
    Write-Ok "already installed: $existing"
} else {
    $installed = $false
    if (-not $SkipWinget -and (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Ok "installing via winget"
        winget install --id Cloudflare.cloudflared --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
        $existing = Test-Installed -Name 'cloudflared' -Dir (Join-Path $ToolsDir 'cloudflared')
        if ($existing) { $installed = $true; Write-Ok $existing }
    }
    if (-not $installed) {
        Write-Ok "downloading release binary"
        $dir = Join-Path $ToolsDir 'cloudflared'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $exe = Join-Path $dir 'cloudflared.exe'
        Invoke-WebRequest -Uri 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe' `
            -OutFile $exe -UseBasicParsing -TimeoutSec 300
        Write-Ok $exe
    }
}

Write-Step "caddy"
$existing = Test-Installed -Name 'caddy' -Dir (Join-Path $ToolsDir 'caddy')
if ($existing) {
    Write-Ok "already installed: $existing"
} else {
    $installed = $false
    if (-not $SkipWinget -and (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Ok "installing via winget"
        winget install --id CaddyServer.Caddy --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
        $existing = Test-Installed -Name 'caddy' -Dir (Join-Path $ToolsDir 'caddy')
        if ($existing) { $installed = $true; Write-Ok $existing }
    }
    if (-not $installed) {
        Write-Ok "downloading release binary"
        $dir = Join-Path $ToolsDir 'caddy'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $zip = Join-Path $dir 'caddy.zip'
        $meta = Invoke-RestMethod 'https://api.github.com/repos/caddyserver/caddy/releases/latest' `
            -TimeoutSec 120 -Headers @{ 'User-Agent' = 'localhost2cloud-skill' }
        $asset = $meta.assets | Where-Object { $_.name -like '*windows_amd64.zip' } | Select-Object -First 1
        if (-not $asset) { throw "Could not find a Windows amd64 Caddy build." }
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing -TimeoutSec 300
        Expand-Archive -Path $zip -DestinationPath $dir -Force
        Remove-Item $zip -Force
        Write-Ok (Join-Path $dir 'caddy.exe')
    }
}

Write-Host ""
Write-Host "Done. Start-Demo.ps1 looks on PATH first, then $ToolsDir." -ForegroundColor Green
