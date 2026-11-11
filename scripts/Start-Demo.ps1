<#
.SYNOPSIS
    Boot any local app stack and print one public link to share.

.DESCRIPTION
    Reads demo.config.json from the current directory or any parent, starts
    every declared service that is not already running, generates a Caddy
    gateway that puts them all behind ONE local origin, then opens a tunnel to
    that origin.

    The result is a single https://<random>.trycloudflare.com address that
    behaves like a cloud-hosted app: the page, its REST calls and any WebSocket
    all share that origin, so nothing in the app needs to know it is remote.

.PARAMETER ConfigPath
    Path to demo.config.json. Omit to auto-discover from the current directory.

.PARAMETER Provider
    Tunnel provider: cloudflare (default), ngrok, or none (local only).

.PARAMETER DevMode
    Start services with their devMode args instead of production args.

.PARAMETER Force
    Tear down any recorded session first, then boot fresh.

.EXAMPLE
    .\Start-Demo.ps1
    .\Start-Demo.ps1 -Provider none
    .\Start-Demo.ps1 -ConfigPath D:\Projects\Other\demo.config.json -Force
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [ValidateSet('cloudflare','ngrok','none')][string]$Provider = 'cloudflare',
    [switch]$DevMode,
    [switch]$Force,
    [string]$CloudflaredPath,
    [string]$NgrokPath,
    [string]$CaddyPath
)

. (Join-Path $PSScriptRoot 'common.ps1')

$config = Get-DemoConfig -ConfigPath $ConfigPath
$data   = $config.Data
Write-Step "Project: $($config.Dir)"

# --- 0. Existing session ---------------------------------------------------
$existing = Get-DemoState -Config $config
if ($existing -and -not $Force) {
    $tunnelAlive = $false
    if ($existing.Pids -and $existing.Pids.Tunnel) {
        $tunnelAlive = [bool](Get-Process -Id $existing.Pids.Tunnel -ErrorAction SilentlyContinue)
    }
    if ($tunnelAlive) {
        Write-Bad "A demo is already running for this project."
        Write-Host "    URL: $($existing.Url)" -ForegroundColor Green
        Write-Host "    Re-run with -Force to restart, or run Stop-Demo.ps1 first." -ForegroundColor Yellow
        return
    }
    Write-Warn2 "Found a stale session record; cleaning it up"
    Clear-DemoState -Config $config
}

# --- 1. Tools --------------------------------------------------------------
Write-Step "Resolving tools"
$caddy = Resolve-Tool -Name 'caddy' -ExplicitPath $CaddyPath -FallbackDirs @('D:\Tools\caddy','C:\Tools\caddy')
Write-Ok "caddy: $caddy"

$tunnelExe = $null
if ($Provider -eq 'cloudflare') {
    $tunnelExe = Resolve-Tool -Name 'cloudflared' -ExplicitPath $CloudflaredPath -FallbackDirs @('D:\Tools\cloudflared','C:\Tools\cloudflared')
    Write-Ok "cloudflared: $tunnelExe"
} elseif ($Provider -eq 'ngrok') {
    $tunnelExe = Resolve-Tool -Name 'ngrok' -ExplicitPath $NgrokPath -FallbackDirs @('D:\Tools\ngrok','C:\Tools\ngrok')
    Write-Ok "ngrok: $tunnelExe"
} else {
    Write-Ok "provider 'none' - gateway only, reachable on this machine"
}

# --- 2. Services -----------------------------------------------------------
$pids = [ordered]@{}
$starts = [ordered]@{}

foreach ($svc in $data.services) {
    Write-Step "Service '$($svc.name)' on port $($svc.port)"

    if (Test-PortOpen -Port $svc.port) {
        $owner = Get-PortOwner -Port $svc.port
        if (Wait-Health -Url $svc.healthUrl -TimeoutSeconds 20 -Label "'$($svc.name)'") {
            $pidNote = ''
            if ($owner) { $pidNote = " (pid $($owner.Pid))" }
            Write-Ok "Already running and healthy$pidNote - reusing"
            $pids[$svc.name] = $null
            continue
        }
        $who = if ($owner) { "$($owner.Name) (pid $($owner.Pid))" } else { 'an unknown process' }
        throw "Port $($svc.port) is held by $who but $($svc.healthUrl) is not responding. Stop that process first - the skill will not kill something it did not start."
    }

    if ($svc.managed -eq $false) {
        throw "Service '$($svc.name)' is not running on port $($svc.port) and is marked managed:false (the skill will not start it). Start it yourself, then re-run."
    }

    # NB: never name this $args - that is a reserved automatic variable.
    $launchArgs = @()
    $startArgs = $svc.startArgs
    if ($DevMode -and $svc.devMode -and $svc.devMode.startArgs) { $startArgs = $svc.devMode.startArgs }
    if ($startArgs) { foreach ($a in $startArgs) { $launchArgs += [string]$a } }

    $exe = $svc.command
    if (-not $exe) { throw "Service '$($svc.name)' has no command[] and is not running." }

    $exePath = (Get-Command $exe -ErrorAction SilentlyContinue)
    if ($exePath) { $exe = $exePath.Source }

    $workDir = $config.Dir
    if ($svc.dir) { $workDir = Join-Path $config.Dir $svc.dir }

    # Build before a production start. A config that declares buildArgs without
    # buildCommand is a mistake, not a no-op - fail loudly instead of silently
    # starting a stale bundle.
    if ($DevMode) {
        # dev servers compile on demand
    } elseif ($svc.buildCommand) {
        $buildArgs = @()
        if ($svc.buildArgs) { foreach ($a in $svc.buildArgs) { $buildArgs += [string]$a } }
        Write-Ok "Building: $($svc.buildCommand) $($buildArgs -join ' ')"
        Push-Location $workDir
        try {
            & $svc.buildCommand @buildArgs
            if ($LASTEXITCODE -ne 0) { throw "Build failed for '$($svc.name)' (exit $LASTEXITCODE)" }
        } finally { Pop-Location }
        Write-Ok "Build OK"
    } elseif ($svc.buildArgs) {
        throw "Service '$($svc.name)' declares buildArgs but no buildCommand. Set buildCommand to the executable that runs the build."
    }

    $proc = Start-LoggedProcess -FilePath $exe -ArgumentList $launchArgs -Name $svc.name -WorkingDirectory $workDir -LogDir (Get-StateDir -Config $config)
    $pids[$svc.name] = $proc.Pid
    $starts[$svc.name] = Get-ProcessStart -ProcessId $proc.Pid
    Write-Ok "Started (pid $($proc.Pid))"

    if (-not (Wait-Health -Url $svc.healthUrl -TimeoutSeconds 150 -Label "'$($svc.name)'")) {
        Write-Bad "Log tail:"
        Get-LogText -OutLog $proc.OutLog -ErrLog $proc.ErrLog | Select-Object -Last 25 | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
        throw "Service '$($svc.name)' did not become ready."
    }
    Write-Ok "Ready"
}

# --- 3. Gateway ------------------------------------------------------------
$gw = $data.gateway
Write-Step "Gateway on port $($gw.port)"
if (Test-PortOpen -Port $gw.port) {
    $owner = Get-PortOwner -Port $gw.port
    $ownerNote = ''
    if ($owner) { $ownerNote = " by $($owner.Name) (pid $($owner.Pid))" }
    throw "Port $($gw.port) is already in use$ownerNote. Change gateway.port in demo.config.json."
}

$caddyfilePath = Join-Path (Get-StateDir -Config $config) 'Caddyfile.generated'
$gatewayInfo = New-Caddyfile -Config $config -OutPath $caddyfilePath
Write-Ok "Routes: $($gatewayInfo.ExposedPrefixes) prefix(es) -> services, default -> '$($gatewayInfo.DefaultService)'"

$gwProc = Start-LoggedProcess -FilePath $caddy -ArgumentList @('run','--config',$caddyfilePath,'--adapter','caddyfile') -Name 'gateway' -WorkingDirectory $config.Dir -LogDir (Get-StateDir -Config $config)
$pids['gateway'] = $gwProc.Pid
$starts['gateway'] = Get-ProcessStart -ProcessId $gwProc.Pid
Write-Ok "Started (pid $($gwProc.Pid))"

$gwHealth = "http://127.0.0.1:$($gw.port)/"
if (-not (Wait-Gateway -Url $gwHealth -TimeoutSeconds 30)) {
    Get-LogText -OutLog $gwProc.OutLog -ErrLog $gwProc.ErrLog | Select-Object -Last 25 | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
    throw "Gateway did not come up."
}
Write-Ok "Ready"

# --- 4. Tunnel -------------------------------------------------------------
$publicUrl = $null
$tunnelPid = $null

if ($Provider -eq 'none') {
    Write-Step "No tunnel requested"
    $publicUrl = "http://127.0.0.1:$($gw.port)"
    Write-Ok "Local only: $publicUrl"
} else {
    Write-Step "Opening $Provider tunnel"
    $target = "http://127.0.0.1:$($gw.port)"
    $tunnelArgs = @()
    if ($Provider -eq 'cloudflare') {
        $tunnelArgs = @('tunnel','--url',$target,'--no-autoupdate')
        $urlPattern = 'https://[a-z0-9-]+\.trycloudflare\.com'
    } else {
        $tunnelArgs = @('http', $target, '--log', 'stdout', '--log-format', 'json')
        $urlPattern = 'https://[a-z0-9-]+\.ngrok-free\.(app|dev)'
    }

    $tunProc = Start-LoggedProcess -FilePath $tunnelExe -ArgumentList $tunnelArgs -Name 'tunnel' -WorkingDirectory $config.Dir -LogDir (Get-StateDir -Config $config)
    $tunnelPid = $tunProc.Pid
    $pids['tunnel'] = $tunnelPid
    $starts['tunnel'] = Get-ProcessStart -ProcessId $tunnelPid

    $deadline = (Get-Date).AddSeconds(100)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 600
        $text = Get-LogText -OutLog $tunProc.OutLog -ErrLog $tunProc.ErrLog
        if ($text -match $urlPattern) { $publicUrl = $matches[0]; break }
        if (-not (Get-Process -Id $tunProc.Pid -ErrorAction SilentlyContinue)) {
            Get-LogText -OutLog $tunProc.OutLog -ErrLog $tunProc.ErrLog | Select-Object -Last 20 | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
            throw "The tunnel process exited before printing a URL."
        }
    }
    if (-not $publicUrl) {
        Get-LogText -OutLog $tunProc.OutLog -ErrLog $tunProc.ErrLog | Select-Object -Last 20 | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
        throw "Could not read the public URL from the tunnel log."
    }
    Write-Ok $publicUrl
}

# --- 5. Verify from the public internet ------------------------------------
Write-Step "Verifying from outside this machine"
$checks = @()

foreach ($svc in $data.services) {
    if (-not $svc.healthUrl) { continue }
    $path = ([uri]$svc.healthUrl).PathAndQuery
    if (-not $path) { $path = '/' }
    if ($svc.verifyPath) { $path = $svc.verifyPath }
    $accept = @()
    if ($svc.acceptStatus) { foreach ($c in $svc.acceptStatus) { $accept += [int]$c } }
    $url = "$publicUrl$path"
    $ok = $false
    # Quick tunnels need DNS to propagate at the Cloudflare edge; a fresh
    # hostname can take ~40-75s before the first request is served. Budget for
    # that instead of reporting a false failure on a working link.
    for ($i = 1; $i -le 15; $i++) {
        if (Test-Health -Url $url -TimeoutSeconds 20 -AcceptStatus $accept) { $ok = $true; break }
        Start-Sleep -Seconds 5
    }
    $checks += [pscustomobject]@{ What = "$($svc.name) $path"; Url = $url; Ok = $ok }
    if ($ok) { Write-Ok "$($svc.name) $path" } else { Write-Warn2 "$($svc.name) $path (not answering yet)" }
}

# --- 6. Save + report ------------------------------------------------------
$state = [pscustomobject]@{
    Project   = $config.Dir
    ConfigPath= $config.Path
    Provider  = $Provider
    Url       = $publicUrl
    StartedAt = (Get-Date).ToString('o')
    DevMode   = [bool]$DevMode
    Pids      = [pscustomobject]$pids
    Starts    = [pscustomobject]$starts
    Checks    = $checks
}
Save-DemoState -Config $config -State $state

$allOk = -not ($checks | Where-Object { -not $_.Ok })
$warnings = @()
foreach ($svc in $data.services) {
    if ($svc.note) { $warnings += "$($svc.name): $($svc.note)" }
}
if ($data.notes) { foreach ($n in $data.notes) { $warnings += $n } }

Write-Host ""
Write-Host ("=" * 70) -ForegroundColor DarkGray
Write-Host "  SHARE THIS LINK" -ForegroundColor White
Write-Host ""
Write-Host "  $publicUrl" -ForegroundColor Green
Write-Host ""
Write-Host ("=" * 70) -ForegroundColor DarkGray
if ($allOk) {
    Write-Host "  All checks passed from the public internet." -ForegroundColor Green
} else {
    Write-Host "  Some checks failed - run Status-Demo.ps1 for detail." -ForegroundColor Yellow
}
Write-Host "  Anyone with the link can open it. Share it only with the demo audience." -ForegroundColor DarkGray
Write-Host "  When they are done:  Stop-Demo.ps1" -ForegroundColor DarkGray
if ($warnings.Count -gt 0) {
    Write-Host ""
    foreach ($w in $warnings) { Write-Host "  note: $w" -ForegroundColor DarkGray }
}
Write-Host ""
