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
    # Do NOT filter on -State Listen. On Windows 11 (build 26200 observed) the
    # listener row can come back with an EMPTY State string while still carrying
    # the right OwningProcess, so -State Listen returns nothing and we would
    # report a null owner. Query the port, then pick the row that actually names
    # a process.
    param([int]$Port)
    $conn = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue |
        Where-Object { $_.OwningProcess -and $_.OwningProcess -gt 0 } |
        Select-Object -First 1
    if ($conn) {
        $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
        return [pscustomobject]@{
            Pid  = [int]$conn.OwningProcess
            Name = if ($proc) { $proc.ProcessName } else { 'unknown' }
        }
    }

    # netstat fallback for adapters Get-NetTCPConnection misses.
    $line = netstat -ano | Select-String ":$Port\s" | Select-String 'LISTENING' | Select-Object -First 1
    if (-not $line) { return $null }
    $token = ($line.ToString().Trim() -split '\s+')[-1]
    if ($token -notmatch '^\d+$') { return $null }
    $owningPid = [int]$token
    if ($owningPid -le 0) { return $null }
    $p = Get-Process -Id $owningPid -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Pid = $owningPid; Name = if ($p) { $p.ProcessName } else { 'unknown' } }
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

# --- Boot lock ---------------------------------------------------------------
# Two concurrent boots race between "is the port free" and "bind the port",
# leaving a duplicate gateway or half-written state. On POSIX we use a directory;
# on Windows the equivalent atomic primitive is CreateNew, which fails if the
# file already exists.

function Get-BootLockPath {
    param([string]$ProjectDir)
    $safe = ($ProjectDir -replace '[^A-Za-z0-9]', '_')
    if ($safe.Length -gt 100) { $safe = $safe.Substring($safe.Length - 100) }
    return Join-Path $env:TEMP "localhost2cloud-$safe.lock"
}

function Enter-BootLock {
    param([string]$ProjectDir)
    $path = Get-BootLockPath -ProjectDir $ProjectDir
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        try {
            $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $bytes = [Text.Encoding]::UTF8.GetBytes([string]$PID)
            $fs.Write($bytes, 0, $bytes.Length)
            $fs.Close()
            $script:BootLockPath = $path
            return $true
        } catch [System.IO.IOException] {
            # Lock exists. Reclaim it only if its owner is provably gone.
            # Parse defensively: a trailing newline or stray whitespace must not
            # turn a LIVE owner into 0, which would look like a dead lock and let
            # two boots run at once.
            $ownerPid = 0
            $rawOwner = $null
            try { $rawOwner = (Get-Content $path -Raw -ErrorAction Stop) } catch { }
            if ($null -ne $rawOwner) {
                $trimmed = ([string]$rawOwner).Trim()
                if ($trimmed -match '^\d+$') { $ownerPid = [int]$trimmed }
            }
            if ($ownerPid -gt 0) {
                if (Get-Process -Id $ownerPid -ErrorAction SilentlyContinue) {
                    return $false   # live owner: refuse
                }
                Write-Warn2 "Clearing a stale boot lock (pid $ownerPid is gone)"
            } else {
                Write-Warn2 "Clearing an unreadable boot lock"
            }
            Remove-Item $path -Force -ErrorAction SilentlyContinue
        } catch {
            return $false
        }
    }
    return $false
}

function Exit-BootLock {
    if ($script:BootLockPath -and (Test-Path $script:BootLockPath)) {
        Remove-Item $script:BootLockPath -Force -ErrorAction SilentlyContinue
    }
    $script:BootLockPath = $null
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
    # Write to a sibling then move, so a kill mid-write cannot leave truncated
    # JSON that would make the session unreadable exactly when recovery needs it.
    $tmp = "$file.tmp"
    $State | ConvertTo-Json -Depth 8 | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $file -Force
}

function Save-SessionJournal {
    # Persist what has been started SO FAR, before the boot has finished.
    # Without this a hard kill (terminal closed, taskkill /F, reboot) leaves no
    # record at all and the orphaned services can never be found again.
    # Complete=$false tells Stop-Demo.ps1 this is a partial boot to clean up.
    param($Config, $Pids, $Starts, [string]$Url = $null, [string]$Provider = $null)
    $state = [pscustomobject]@{
        Project   = $Config.Dir
        ConfigPath= $Config.Path
        Provider  = $Provider
        Url       = $Url
        StartedAt = (Get-Date).ToString('o')
        DevMode   = $false
        Pids      = [pscustomobject]$Pids
        Starts    = [pscustomobject]$Starts
        Complete  = $false
        Checks    = @()
    }
    Save-DemoState -Config $Config -State $state
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

    # Auth wraps every route, before any handle block, so a request cannot reach
    # an upstream without passing it.
    $auth = $Config.Data.auth
    if ($auth -and $auth.enabled -eq $true) {
        $user = if ($auth.username) { $auth.username } else { 'demo' }
        $hash = if ($auth.passwordHash) { [string]$auth.passwordHash } else { '' }
        if (-not $hash -and $auth.password) {
            $hash = (& $script:CaddyBin hash-password --plaintext ([string]$auth.password) 2>$null)
            if (-not $hash) { throw "Could not hash the demo password with caddy." }
        }
        if (-not $hash) { throw "auth is enabled but neither auth.passwordHash nor auth.password is set." }
        $lines += "`tbasic_auth {"
        $lines += "`t`t$user $hash"
        $lines += "`t}"
        $lines += ''
    }

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
