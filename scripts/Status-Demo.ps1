<#
.SYNOPSIS
    Show whether the demo and its public link are still alive.

.DESCRIPTION
    Checks each process, each local port, the gateway routing, and the public
    URL end to end, then reprints the link so it can be re-shared without a
    reboot. Exit code 0 when everything is healthy, 1 otherwise.

.PARAMETER ConfigPath
    Path to demo.config.json. Omit to auto-discover.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath
)

. (Join-Path $PSScriptRoot 'common.ps1')

$config = Get-DemoConfig -ConfigPath $ConfigPath
$state  = Get-DemoState -Config $config

if (-not $state) {
    Write-Host "No demo running for $($config.Dir). Run Start-Demo.ps1." -ForegroundColor Yellow
    exit 1
}

Write-Step "Session started $($state.StartedAt) (provider: $($state.Provider))"
Write-Host ""

$healthy = $true

$rows = @()
$rows += [pscustomobject]@{ Component = 'tunnel'; Pid = $state.Pids.Tunnel; Start = $(if ($state.Starts) { $state.Starts.Tunnel } else { '' }) }
$rows += [pscustomobject]@{ Component = 'gateway'; Pid = $state.Pids.Gateway; Start = $(if ($state.Starts) { $state.Starts.Gateway } else { '' }) }
foreach ($svc in $config.Data.services) {
    $svcStart = ''
    if ($state.Starts -and $state.Starts.PSObject.Properties[$svc.name]) { $svcStart = [string]$state.Starts.($svc.name) }
    $rows += [pscustomobject]@{ Component = $svc.name; Pid = $state.Pids.($svc.name); Start = $svcStart }
}

foreach ($row in $rows) {
    if ($row.Pid) {
        $p = Get-Process -Id $row.Pid -ErrorAction SilentlyContinue
        if (-not $p) {
            Write-Host ("  {0,-12} DOWN (was pid {1})" -f $row.Component, $row.Pid) -ForegroundColor Red
            $healthy = $false
        } elseif (-not (Test-ProcessMatches -ProcessId $row.Pid -RecordedStart ([string]$row.Start))) {
            Write-Host ("  {0,-12} DOWN (pid {1} was reused by another process)" -f $row.Component, $row.Pid) -ForegroundColor Red
            $healthy = $false
        } else {
            Write-Host ("  {0,-12} running (pid {1})" -f $row.Component, $row.Pid) -ForegroundColor Green
        }
    } else {
        Write-Host ("  {0,-12} external (not started by the demo)" -f $row.Component) -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Step "Ports"
foreach ($svc in $config.Data.services) {
    $open = Test-PortOpen -Port $svc.port
    $h = Test-Health -Url $svc.healthUrl
    $label = "port $($svc.port)"
    if ($open -and $h) { Write-Host "  $($svc.name.PadRight(12)) $label open, health OK" -ForegroundColor Green }
    elseif ($open) { Write-Host "  $($svc.name.PadRight(12)) $label open, health FAILING" -ForegroundColor Yellow; $healthy = $false }
    else { Write-Host "  $($svc.name.PadRight(12)) $label CLOSED" -ForegroundColor Red; $healthy = $false }
}

Write-Host ""
Write-Step "Gateway"
$gwBase = "http://127.0.0.1:$($config.Data.gateway.port)"
$unrouted = @($config.Data.services | Where-Object { -not $_.expose -and $_.default -ne $true })
foreach ($svc in $config.Data.services) {
    if (-not $svc.expose) { continue }
    foreach ($prefix in $svc.expose) {
        # Probe a path the service actually owns; the prefix root is often 404.
        $probe = "$gwBase$prefix"
        if ($svc.verifyPath) { $probe = "$gwBase$($svc.verifyPath)" }
        $accept = @()
        if ($svc.acceptStatus) { foreach ($c in $svc.acceptStatus) { $accept += [int]$c } }
        $code = $null
        try {
            $r = Invoke-WebRequest -Uri $probe -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
            $code = [int]$r.StatusCode
        } catch {
            if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        }
        $reachable = $false
        if ($code -and $code -lt 500) { $reachable = $true }
        if ($code -and $accept -and ($accept -contains $code)) { $reachable = $true }
        $shown = if ($code) { "HTTP $code" } else { 'no response' }
        if ($reachable) {
            Write-Host "  $prefix -> $($svc.name) : $shown" -ForegroundColor Green
        } else {
            Write-Host "  $prefix -> $($svc.name) : $shown" -ForegroundColor Yellow
            $healthy = $false
        }
    }
}
foreach ($svc in $unrouted) {
    Write-Host "  $($svc.name) : not routed through the gateway (local only on port $($svc.port))" -ForegroundColor DarkGray
}

Write-Host ""
Write-Step "Public URL"
if ($state.Provider -eq 'none') {
    Write-Host "  No tunnel (provider 'none'). Local address only:" -ForegroundColor DarkGray
    Write-Host "  $($state.Url)" -ForegroundColor Green
} else {
    try {
        $r = Invoke-WebRequest -Uri "$($state.Url)/" -TimeoutSec 25 -UseBasicParsing
        Write-Host "  Page: HTTP $($r.StatusCode)" -ForegroundColor Green
    } catch {
        Write-Host "  Page: $($_.Exception.Message)" -ForegroundColor Red
        $healthy = $false
    }
    Write-Host ""
    Write-Host "  $($state.Url)" -ForegroundColor Green
}

Write-Host ""
if ($healthy) {
    Write-Host "Everything checks out." -ForegroundColor Green
    exit 0
} else {
    Write-Host "Something is down. Stop-Demo.ps1 then Start-Demo.ps1 to rebuild." -ForegroundColor Yellow
    exit 1
}
