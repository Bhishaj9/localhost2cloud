# Shared helpers for the localhost2cloud skill (dot-sourced, never run directly).
# Windows PowerShell 5.1 compatible: no ternary, no ??, no &&, no ?.

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Config discovery
# ---------------------------------------------------------------------------
# A project opts in by holding a demo.config.json. Scripts find it by walking up
# from the current directory, so the same skill works in every repo untouched.

function Find-DemoConfig {
    param([string]$ConfigPath)

    if ($ConfigPath) {
        $resolved = (Resolve-Path -Path $ConfigPath -ErrorAction Stop).Path
        if (-not (Test-Path $resolved)) { throw "Config not found: $ConfigPath" }
        return $resolved
    }

    $dir = (Get-Location).Path
    while ($dir) {
        $candidate = Join-Path $dir 'demo.config.json'
        if (Test-Path $candidate) { return (Resolve-Path $candidate).Path }
        $parent = Split-Path -Parent $dir
        if ($parent -eq $dir -or -not $parent) { break }
        $dir = $parent
    }
    throw "No demo.config.json found in this directory or any parent. Copy assets/demo.config.example.json into the project root and edit it."
}

function Get-DemoConfig {
    param([string]$ConfigPath)
    $path = Find-DemoConfig -ConfigPath $ConfigPath
    $cfg = Get-Content $path -Raw | ConvertFrom-Json
    if (-not $cfg.services -or $cfg.services.Count -eq 0) { throw "Config has no services[]: $path" }
    if (-not $cfg.gateway) { throw "Config has no gateway{}: $path" }
    return [pscustomobject]@{ Path = $path; Dir = (Split-Path -Parent $path); Data = $cfg }
}

function Get-ProjectRoot {
    param($Config)
    return $Config.Dir
}

# ---------------------------------------------------------------------------
# Port + health probing
# ---------------------------------------------------------------------------

function Test-PortOpen {
    # Real TCP connect, not Get-NetTCPConnection: a socket in a transient state
    # (FIN_WAIT_1, TIME_WAIT) otherwise reads as both "free" and "busy".
    param([int]$Port, [string]$ComputerName = '127.0.0.1')
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(700)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Get-PortOwner {
    param([int]$Port)
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $conn) {
        # netstat still reports listeners Get-NetTCPConnection misses on some adapters.
        $line = netstat -ano | Select-String ":$Port\s" | Select-String 'LISTENING' | Select-Object -First 1
        if (-not $line) { return $null }
        $owningPid = [int](($line.ToString().Trim() -split '\s+')[-1])
        $p = Get-Process -Id $owningPid -ErrorAction SilentlyContinue
        return [pscustomobject]@{ Pid = $owningPid; Name = if ($p) { $p.ProcessName } else { 'unknown' } }
    }
    $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
    return [pscustomobject]@{
        Pid  = $conn.OwningProcess
        Name = if ($proc) { $proc.ProcessName } else { 'unknown' }
    }
}

function Test-Health {
    # -AcceptStatus lets a service count as reachable when it answers with an
    # expected non-2xx code. Auth-protected endpoints return 401, which proves
    # the request reached the service rather than failing at the proxy.
    param([string]$Url, [int]$TimeoutSeconds = 8, [int[]]$AcceptStatus = @())
    if (-not $Url) { return $true }
    try {
        $r = Invoke-WebRequest -Uri $Url -TimeoutSec $TimeoutSeconds -UseBasicParsing
        return ($r.StatusCode -ge 200 -and $r.StatusCode -lt 400)
    } catch {
        $code = $null
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        if ($code -and $AcceptStatus -and ($AcceptStatus -contains $code)) { return $true }
        return $false
    }
}

function Wait-Health {
    param([string]$Url, [int]$TimeoutSeconds = 90, [string]$Label = $Url)
    if (-not $Url) { return $true }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Health -Url $Url -TimeoutSeconds 10) { return $true }
        Start-Sleep -Milliseconds 1000
    }
    Write-Warn2 "Timed out waiting for $Label"
    return $false
}

# ---------------------------------------------------------------------------
# State (per project, next to the config)
# ---------------------------------------------------------------------------

function Get-StateDir {
    param($Config)
    $d = Join-Path $Config.Dir '.demo-state'
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    return $d
}

function Get-ProcessStart {
    # Stable per-process identity string. Windows also recycles PIDs, so a stale
    # session could otherwise name an unrelated process and we would kill it.
    param([int]$ProcessId)
    try {
        $p = Get-Process -Id $ProcessId -ErrorAction Stop
        return $p.StartTime.ToUniversalTime().ToString('o')
    } catch {
        return ''
    }
}

function Test-ProcessMatches {
    # Returns $true only when this PID is still the process we started.
    # An empty recorded start means the session predates fingerprinting: accept
    # existence, so upgrades don't strand a running demo.
    param([int]$ProcessId, [string]$RecordedStart)
    $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $p) { return $false }
    if (-not $RecordedStart) { return $true }
    $now = Get-ProcessStart -ProcessId $ProcessId
    return ($now -eq $RecordedStart)
}

function Stop-ProcessTree {
    param([int]$ProcessId)
    if (-not $ProcessId) { return }
    & taskkill /PID $ProcessId /T /F 2>&1 | Out-Null
}

function Wait-Gateway {
    # The gateway is ready once ANY HTTP status comes back. Probing "/" and
    # demanding 2xx conflates "Caddy is up" with "the upstream serves a root
    # route" - a service with only /health or /api would 404 and we would
    # wrongly fail the boot.
    param([string]$Url, [int]$TimeoutSeconds = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest -Uri $Url -TimeoutSec 5 -UseBasicParsing
            if ($r.StatusCode -ge 200) { return $true }
        } catch {
            if ($_.Exception.Response) { return $true }  # 4xx/5xx still proves it is listening
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Save-DemoState {
    param($Config, $State)
    $file = Join-Path (Get-StateDir -Config $Config) 'session.json'
    $State | ConvertTo-Json -Depth 8 | Set-Content -Path $file -Encoding UTF8
}

function Get-DemoState {
    param($Config)
    $file = Join-Path (Get-StateDir -Config $Config) 'session.json'
    if (-not (Test-Path $file)) { return $null }
    try { return (Get-Content $file -Raw | ConvertFrom-Json) } catch { return $null }
}

function Clear-DemoState {
    param($Config)
    $file = Join-Path (Get-StateDir -Config $Config) 'session.json'
    Remove-Item $file -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Process launching
# ---------------------------------------------------------------------------

function Start-LoggedProcess {
    # Detached via Start-Process with output captured to files, so the script can
    # read the tunnel URL out of the log and the process survives script exit
    # while remaining killable by PID.
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [Parameter(Mandatory=$true)][string]$Name,
        [string]$WorkingDirectory,
        [string]$LogDir
    )
    if (-not $LogDir) { $LogDir = Join-Path (Get-Location).Path '.demo-state' }
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
    $out = Join-Path $LogDir "$Name.out.log"
    $err = Join-Path $LogDir "$Name.err.log"
    Remove-Item $out, $err -Force -ErrorAction SilentlyContinue

    $params = @{
        FilePath               = $FilePath
        ArgumentList           = $ArgumentList
        PassThru               = $true
        RedirectStandardOutput = $out
        RedirectStandardError  = $err
        WindowStyle            = 'Hidden'
    }
    if ($WorkingDirectory) { $params['WorkingDirectory'] = $WorkingDirectory }
    $proc = Start-Process @params
    return [pscustomobject]@{ Pid = $proc.Id; OutLog = $out; ErrLog = $err; Name = $Name }
}

function Get-LogText {
    param([string]$OutLog, [string]$ErrLog)
    $text = ''
    if ($OutLog -and (Test-Path $OutLog)) { $text += (Get-Content $OutLog -Raw -ErrorAction SilentlyContinue) }
    if ($ErrLog -and (Test-Path $ErrLog)) { $text += (Get-Content $ErrLog -Raw -ErrorAction SilentlyContinue) }
    return $text
}

function Resolve-Tool {
    # Explicit path -> PATH -> known install dir. Keeps the skill portable across
    # machines without hardcoding one layout.
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [string]$ExplicitPath,
        [string[]]$FallbackDirs = @()
    )
    if ($ExplicitPath) {
        if (-not (Test-Path $ExplicitPath)) { throw "Path does not exist: $ExplicitPath" }
        return $ExplicitPath
    }
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($dir in $FallbackDirs) {
        $exe = Join-Path $dir "$Name.exe"
        if (Test-Path $exe) { return $exe }
    }
    throw "'$Name' not found. Install it (winget install $Name) or pass its path."
}

# ---------------------------------------------------------------------------
# Caddyfile generation from config
# ---------------------------------------------------------------------------
# Exactly one origin must front every port the browser touches, because a
# single tunnel can only target one local address.

function New-Caddyfile {
    param($Config, [string]$OutPath)

    $gw = $Config.Data.gateway
    $lines = @()
    $lines += '# GENERATED by localhost2cloud from demo.config.json - do not hand-edit.'
    $lines += '# Regenerated on every boot so the routes always match the config.'
    $lines += ''
    $lines += '{'
    $lines += "`tauto_https off"
    $lines += "`tadmin off"
    $lines += '}'
    $lines += ''
    $lines += ":$($gw.port) {"
    $lines += "`tencode zstd gzip"
    $lines += ''

    $defaultService = $null
    $exposed = 0

    foreach ($svc in $Config.Data.services) {
        if (-not $svc.expose) { continue }
        foreach ($prefix in $svc.expose) {
            $exposed++
            $lines += "`thandle $prefix {"
            $lines += "`t`treverse_proxy 127.0.0.1:$($svc.port) {"
            $lines += "`t`t`theader_up X-Forwarded-Proto https"
            $lines += "`t`t}"
            $lines += "`t}"
            $lines += ''
        }
    }

    foreach ($svc in $Config.Data.services) {
        if ($svc.default -eq $true) { $defaultService = $svc }
    }
    if (-not $defaultService) {
        throw "Config needs exactly one service with `"default`": true to serve everything not matched by expose[]."
    }

    $lines += "`thandle {"
    $lines += "`t`treverse_proxy 127.0.0.1:$($defaultService.port) {"
    $lines += "`t`t`theader_up X-Forwarded-Proto https"
    $lines += "`t`t}"
    $lines += "`t}"
    $lines += '}'
    $lines += ''

    Set-Content -Path $OutPath -Value ($lines -join "`n") -Encoding UTF8
    return [pscustomobject]@{ Path = $OutPath; ExposedPrefixes = $exposed; DefaultService = $defaultService.name }
}

# ---------------------------------------------------------------------------
# Console output
# ---------------------------------------------------------------------------

function Write-Step  { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok    { param([string]$Message) Write-Host "    $Message" -ForegroundColor Green }
function Write-Warn2 { param([string]$Message) Write-Host "    $Message" -ForegroundColor Yellow }
function Write-Bad   { param([string]$Message) Write-Host "    $Message" -ForegroundColor Red }
