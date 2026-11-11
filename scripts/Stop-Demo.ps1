<#
.SYNOPSIS
    Close the public link and stop what the demo booted.

.DESCRIPTION
    Kills the tunnel, the gateway and every service this skill started, using
    the recorded session file. Services that were already running before the
    boot were never owned by the skill and are left alone - except the gateway,
    which the skill always starts itself.

.PARAMETER ConfigPath
    Path to demo.config.json. Omit to auto-discover.

.PARAMETER IncludeReused
    Also stop services that were already running when the demo booted. Use when
    you want the whole stack down, not just the tunnel.

.PARAMETER KeepGateway
    Leave the local gateway running (it is harmless without a tunnel).

.EXAMPLE
    .\Stop-Demo.ps1
    .\Stop-Demo.ps1 -IncludeReused
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$IncludeReused,
    [switch]$KeepGateway
)

. (Join-Path $PSScriptRoot 'common.ps1')

$config = Get-DemoConfig -ConfigPath $ConfigPath
$state  = Get-DemoState -Config $config

if (-not $state) {
    Write-Step "No demo session recorded for $($config.Dir)"
    $leftover = @()
    foreach ($name in 'cloudflared','ngrok','caddy') {
        $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
        foreach ($p in $procs) { $leftover += "$name (pid $($p.Id))" }
    }
    if ($leftover.Count -gt 0) {
        Write-Warn2 "These tunnel/gateway processes are still running and may not belong to a demo:"
        foreach ($l in $leftover) { Write-Host "      $l" -ForegroundColor DarkGray }
        Write-Warn2 "Stop them yourself if they are unwanted; this script will not guess."
    }
    return
}

Write-Step "Closing the public link for $($config.Dir)"
if ($state.Url) { Write-Ok "was: $($state.Url)" }

$order = @('tunnel','gateway')
foreach ($svc in $config.Data.services) { $order += $svc.name }

$stopped = 0
foreach ($name in $order) {
    if ($name -eq 'gateway' -and $KeepGateway) { continue }
    $procId = $null
    if ($state.Pids -and $state.Pids.PSObject.Properties[$name]) {
        $procId = $state.Pids.$name
    }
    if (-not $procId) {
        # null means "was already running at boot". Only touch it if asked.
        if ($name -ne 'tunnel' -and $name -ne 'gateway' -and -not $IncludeReused) {
            Write-Ok "$name : left running (was already up before the demo)"
        }
        continue
    }
    $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if ($p) {
        & taskkill /PID $procId /T /F 2>&1 | Out-Null
        Write-Ok "$name stopped (pid $procId)"
        $stopped++
    } else {
        Write-Ok "$name already gone (pid $procId)"
    }
}

if ($IncludeReused) {
    # With -IncludeReused the reused services are also fair game.
    foreach ($svc in $config.Data.services) {
        $owner = Get-PortOwner -Port $svc.port
        if ($owner) {
            Write-Host "    '$($svc.name)' still holding port $($svc.port): $($owner.Name) (pid $($owner.Pid))" -ForegroundColor Yellow
            Write-Host "      Stop it manually if it should go down - it predates this demo." -ForegroundColor DarkGray
        }
    }
}

Clear-DemoState -Config $config

Write-Host ""
Write-Host "Demo closed. The public URL no longer resolves to this machine." -ForegroundColor Green
if ($stopped -eq 0) {
    Write-Host "Nothing was running under this session." -ForegroundColor DarkGray
}
