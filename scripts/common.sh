#!/usr/bin/env bash
# Shared helpers for localhost2cloud (sourced, never executed directly).
#
# POSIX counterpart to common.ps1. Same behaviour contract:
#   - config discovered by walking up from the current directory
#   - every browser request funnelled through ONE origin (Caddy), because a
#     single tunnel can only target one local address
#   - never kill a process this skill did not start
#
# Requires bash (not plain sh) and curl. Needs python3 or jq to read JSON.

set -o pipefail

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'; C_GREY=$'\033[90m'; C_RESET=$'\033[0m'
else
  C_CYAN=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_GREY=''; C_RESET=''
fi

step() { printf '%s==> %s%s\n' "$C_CYAN" "$*" "$C_RESET"; }
ok()   { printf '%s    %s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
warn() { printf '%s    %s%s\n' "$C_YELLOW" "$*" "$C_RESET"; }
bad()  { printf '%s    %s%s\n' "$C_RED" "$*" "$C_RESET"; }
grey() { printf '%s    %s%s\n' "$C_GREY" "$*" "$C_RESET"; }

die() {
  # A fatal error during a boot must not strand the lock.
  if [ "${BOOT_LOCK_HELD:-0}" = 1 ]; then release_boot_lock 2>/dev/null || true; fi
  bad "$*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# JSON backend
# ---------------------------------------------------------------------------
# python3 ships with macOS (CLT) and every mainstream Linux; jq is the common
# alternative. Requiring one of the two keeps the scripts dependency-light
# without hand-rolling a JSON parser.

json_backend() {
  if command -v python3 >/dev/null 2>&1; then echo python3
  elif command -v jq >/dev/null 2>&1; then echo jq
  else echo none
  fi
}

require_json_backend() {
  [ "$(json_backend)" = none ] && \
    die "Need python3 or jq to read JSON configs. Install one of them and retry."
  return 0
}

# ---------------------------------------------------------------------------
# Config discovery + loading
# ---------------------------------------------------------------------------
# A project opts in by holding a demo.config.json. Walking up means the same
# skill works in any repo without flags.

# Prints the absolute path of the config, or fails.
find_config() {
  local explicit="${1:-}"
  if [ -n "$explicit" ]; then
    [ -f "$explicit" ] || die "Config not found: $explicit"
    printf '%s/%s' "$(cd "$(dirname "$explicit")" && pwd)" "$(basename "$explicit")"
    return 0
  fi
  local dir
  dir="$(pwd)"
  while :; do
    if [ -f "$dir/demo.config.json" ]; then
      echo "$dir/demo.config.json"
      return 0
    fi
    local parent
    parent="$(dirname "$dir")"
    [ "$parent" = "$dir" ] && break
    dir="$parent"
  done
  die "No demo.config.json found in this directory or any parent. Copy assets/demo.config.example.json into the project root and edit it."
}

# Loads the config into shell variables:
#   CFG_PATH, CFG_DIR, GW_PORT, SVC_COUNT
#   SVC_<i>_NAME|COMMAND|PORT|HEALTHURL|DIR|VERIFY|ACCEPT|MANAGED|DEFAULT|NOTE
#   SVC_<i>_START (newline-joined), SVC_<i>_BUILD, SVC_<i>_BUILDARGS
#   SVC_<i>_EXPOSE (space-joined), SVC_<i>_DEVSTART
#   NOTES (newline-joined)
load_config() {
  require_json_backend
  CFG_PATH="$(find_config "${1:-}")" || exit 1
  CFG_DIR="$(cd "$(dirname "$CFG_PATH")" && pwd)"

  local backend; backend="$(json_backend)"
  if [ "$backend" = python3 ]; then
    eval "$(python3 - "$CFG_PATH" <<'PY'
import json, sys, shlex
q = shlex.quote
path = sys.argv[1]
try:
    cfg = json.load(open(path, encoding='utf-8-sig'))
except Exception as e:
    sys.stderr.write("Could not parse %s: %s\n" % (path, e))
    sys.exit(1)

svcs = cfg.get('services') or []
if not svcs:
    sys.stderr.write("Config has no services[]: %s\n" % path)
    sys.exit(1)
gw = cfg.get('gateway') or {}
if not gw.get('port'):
    sys.stderr.write("Config has no gateway.port: %s\n" % path)
    sys.exit(1)

out = []
out.append('GW_PORT=%s' % q(str(gw.get('port'))))
out.append('SVC_COUNT=%d' % len(svcs))
for i, s in enumerate(svcs):
    p = 'SVC_%d_' % i
    out.append(p + 'NAME=' + q(str(s.get('name', 'svc%d' % i))))
    out.append(p + 'COMMAND=' + q(str(s.get('command') or '')))
    out.append(p + 'PORT=' + q(str(s.get('port') or '')))
    out.append(p + 'HEALTHURL=' + q(str(s.get('healthUrl') or '')))
    out.append(p + 'DIR=' + q(str(s.get('dir') or '')))
    out.append(p + 'VERIFY=' + q(str(s.get('verifyPath') or '')))
    out.append(p + 'NOTE=' + q(str(s.get('note') or '')))
    out.append(p + 'BUILD=' + q(str(s.get('buildCommand') or '')))
    out.append(p + 'START=' + q('\n'.join(str(a) for a in (s.get('startArgs') or []))))
    out.append(p + 'BUILDARGS=' + q('\n'.join(str(a) for a in (s.get('buildArgs') or []))))
    out.append(p + 'EXPOSE=' + q(' '.join(str(a) for a in (s.get('expose') or []))))
    accept = s.get('acceptStatus') or []
    out.append(p + 'ACCEPT=' + q(' '.join(str(a) for a in accept)))
    out.append(p + 'MANAGED=' + q('false' if s.get('managed') is False else 'true'))
    out.append(p + 'DEFAULT=' + q('true' if s.get('default') is True else 'false'))
    dev = (s.get('devMode') or {}).get('startArgs') or []
    out.append(p + 'DEVSTART=' + q('\n'.join(str(a) for a in dev)))
notes = cfg.get('notes') or []
out.append('NOTES=' + q('\n'.join(str(n) for n in notes)))
print('\n'.join(out))
PY
)" || exit 1
  else
    # jq's @sh escapes values for safe shell consumption (single-quoted, with
    # embedded quotes handled), so no hand-rolled quoting is needed.
    eval "$(jq -r '
      "GW_PORT=" + ((.gateway.port | tostring) | @sh),
      "SVC_COUNT=" + ((.services | length) | tostring),
      ( .services | to_entries[]
        | .key as $i
        | .value as $s
        | ("SVC_" + ($i|tostring) + "_NAME="     + (($s.name // ("svc" + ($i|tostring))) | tostring | @sh)),
          ("SVC_" + ($i|tostring) + "_COMMAND="  + (($s.command // "") | tostring | @sh)),
          ("SVC_" + ($i|tostring) + "_PORT="     + (($s.port // "") | tostring | @sh)),
          ("SVC_" + ($i|tostring) + "_HEALTHURL="+ (($s.healthUrl // "") | tostring | @sh)),
          ("SVC_" + ($i|tostring) + "_DIR="      + (($s.dir // "") | tostring | @sh)),
          ("SVC_" + ($i|tostring) + "_VERIFY="   + (($s.verifyPath // "") | tostring | @sh)),
          ("SVC_" + ($i|tostring) + "_NOTE="     + (($s.note // "") | tostring | @sh)),
          ("SVC_" + ($i|tostring) + "_BUILD="    + (($s.buildCommand // "") | tostring | @sh)),
          ("SVC_" + ($i|tostring) + "_START="    + (((($s.startArgs // []) | map(tostring) | join("\n"))) | @sh)),
          ("SVC_" + ($i|tostring) + "_BUILDARGS="+ (((($s.buildArgs // []) | map(tostring) | join("\n"))) | @sh)),
          ("SVC_" + ($i|tostring) + "_EXPOSE="   + (((($s.expose // []) | map(tostring) | join(" "))) | @sh)),
          ("SVC_" + ($i|tostring) + "_ACCEPT="   + (((($s.acceptStatus // []) | map(tostring) | join(" "))) | @sh)),
          ("SVC_" + ($i|tostring) + "_MANAGED="  + ((if $s.managed == false then "false" else "true" end) | @sh)),
          ("SVC_" + ($i|tostring) + "_DEFAULT="  + ((if $s.default == true  then "true"  else "false" end) | @sh)),
          ("SVC_" + ($i|tostring) + "_DEVSTART=" + (((($s.devMode.startArgs // []) | map(tostring) | join("\n"))) | @sh))
      ),
      ("NOTES=" + (((.notes // []) | map(tostring) | join("\n")) | @sh))
    ' "$CFG_PATH")" || exit 1
  fi
}

svc_var() { local i="$1" f="$2"; eval "printf '%s' \"\${SVC_${i}_${f}}\""; }

# service_dir <i> -> absolute working directory for a service
service_dir() {
  local i="$1" d; d="$(svc_var "$i" DIR)"
  if [ -n "$d" ]; then printf '%s/%s' "$CFG_DIR" "$d"; else printf '%s' "$CFG_DIR"; fi
}

# ---------------------------------------------------------------------------
# Port + health probing
# ---------------------------------------------------------------------------

# Real TCP connect. A socket in a transient state (TIME_WAIT) otherwise reads
# as both "free" and "busy".
port_open() {
  local port="$1"
  [ -n "$port" ] || return 1
  if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
    exec 3<&- 3>&-
    return 0
  fi
  return 1
}

# Prints "pid|name" for the listener on a port, or nothing.
port_owner() {
  local port="$1" pid=''
  if command -v lsof >/dev/null 2>&1; then
    pid="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | head -n1)"
  fi
  if [ -z "$pid" ] && command -v ss >/dev/null 2>&1; then
    pid="$(ss -ltnp 2>/dev/null \
      | awk -v p=":$port" '$4 ~ p {print $NF}' \
      | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | head -n1)"
  fi
  if [ -z "$pid" ] && command -v netstat >/dev/null 2>&1; then
    pid="$(netstat -an -p tcp 2>/dev/null \
      | awk -v p="[.:]$port " '$0 ~ p && $NF ~ /^[0-9]+$/ {print $NF}' | head -n1)"
  fi
  [ -n "$pid" ] || return 1
  local name; name="$(ps -p "$pid" -o comm= 2>/dev/null | head -n1)"
  printf '%s|%s' "$pid" "${name:-unknown}"
}

# http_code URL [timeout] -> 3-digit code (000 on failure)
http_code() {
  local url="$1" timeout="${2:-8}"
  command -v curl >/dev/null 2>&1 || { echo 000; return 0; }
  curl -s -o /dev/null -w '%{http_code}' --max-time "$timeout" "$url" 2>/dev/null || echo 000
}

# health_ok URL [timeout] [accepted-codes]
# Accepted codes matter because auth-gated endpoints answer 401, which proves
# the request reached the service rather than failing at the proxy.
health_ok() {
  local url="$1" timeout="${2:-8}" accept="${3:-}"
  [ -z "$url" ] && return 0
  local code; code="$(http_code "$url" "$timeout")"
  case "$code" in 2??|3??) return 0 ;; esac
  local a
  for a in $accept; do [ "$code" = "$a" ] && return 0; done
  return 1
}

wait_health() {
  local url="$1" timeout="${2:-90}" label="${3:-$url}"
  [ -z "$url" ] && return 0
  local deadline; deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    health_ok "$url" 10 "" && return 0
    sleep 1
  done
  warn "Timed out waiting for $label"
  return 1
}

# wait_gateway URL [timeout]
# The gateway is ready once ANY HTTP status comes back. Probing "/" and demanding
# 2xx conflates "Caddy is up" with "the upstream serves a root route" - a service
# with only /health or /api would 404 and we would wrongly fail the boot.
wait_gateway() {
  local url="$1" timeout="${2:-30}"
  local deadline; deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local code; code="$(http_code "$url" 5)"
    [ "$code" != 000 ] && return 0
    sleep 0.5
  done
  return 1
}

# ---------------------------------------------------------------------------
# State (per project, next to the config)
# ---------------------------------------------------------------------------

state_dir() {
  local d="$CFG_DIR/.demo-state"
  mkdir -p "$d"
  printf '%s' "$d"
}

# save_state <url> <provider> <devmode> then NAME=pid|start pairs.
# Pids[name] holds the numeric pid (or null); Starts[name] holds the identity
# string. Keeping them separate keeps the JSON readable and makes "null pid,
# reused process" representable.
save_state() {
  local url="$1" provider="$2" devmode="$3"; shift 3
  local dir; dir="$(state_dir)"
  local file="$dir/session.json"
  if [ "$(json_backend)" = python3 ]; then
    python3 - "$file" "$CFG_PATH" "$CFG_DIR" "$url" "$provider" "$devmode" "$@" <<'PY'
import json, sys, datetime
file, cfgpath, cfgdir, url, provider, devmode = sys.argv[1:7]
pairs = sys.argv[7:]
pids, starts = {}, {}
for p in pairs:
    k, _, v = p.partition('=')
    pid, _, start = v.partition('|')
    pids[k] = int(pid) if pid.strip().isdigit() else None
    starts[k] = start or None
state = {
    "Project": cfgdir,
    "ConfigPath": cfgpath,
    "Provider": provider,
    "Url": url,
    "StartedAt": datetime.datetime.now().astimezone().isoformat(),
    "DevMode": devmode == "true",
    "Pids": pids,
    "Starts": starts,
}
json.dump(state, open(file, 'w', encoding='utf-8'), indent=2)
PY
  else
    # jq fallback: build the JSON without a JSON parser on the shell side.
    local pids_json='{' starts_json='{' first=1
    for p in "$@"; do
      local k="${p%%=*}" v="${p#*=}" pid="${v%%|*}" start="${v#*|}"
      [ $first -eq 1 ] || { pids_json="$pids_json,"; starts_json="$starts_json,"; }
      first=0
      if [ -n "$pid" ]; then pids_json="$pids_json\"$k\":$pid"; else pids_json="$pids_json\"$k\":null"; fi
      if [ -n "$start" ]; then starts_json="$starts_json\"$k\":\"$(printf '%s' "$start" | sed 's/"/\\"/g')\""; else starts_json="$starts_json\"$k\":null"; fi
    done
    pids_json="$pids_json}"; starts_json="$starts_json}"
    printf '{"Project":"%s","ConfigPath":"%s","Provider":"%s","Url":"%s","DevMode":%s,"Pids":%s,"Starts":%s}\n' \
      "$CFG_DIR" "$CFG_PATH" "$provider" "$url" "$([ "$devmode" = true ] && echo true || echo false)" \
      "$pids_json" "$starts_json" > "$file"
  fi
}

# state_get <field> -> value (empty if no session)
state_get() {
  local field="$1" file="$CFG_DIR/.demo-state/session.json"
  [ -f "$file" ] || return 1
  if [ "$(json_backend)" = python3 ]; then
    python3 - "$file" "$field" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception:
    sys.exit(1)
v = d
for part in sys.argv[2].split('.'):
    if not isinstance(v, dict) or part not in v:
        sys.exit(1)
    v = v[part]
print('' if v is None else v)
PY
  else
    jq -r --arg f "$field" 'getpath($f | split(".")) | if . == null then "" else tostring end' "$file" 2>/dev/null
  fi
}

has_state() { [ -f "$CFG_DIR/.demo-state/session.json" ]; }

clear_state() { rm -f "$CFG_DIR/.demo-state/session.json"; }

# ---------------------------------------------------------------------------
# Boot lock
# ---------------------------------------------------------------------------
# Two concurrent boots race between "is the port free" and "bind the port",
# which yields duplicate gateways or half-written state. mkdir is atomic on
# every POSIX filesystem, which makes it a portable lock without flock(1).

# Computed lazily: CFG_DIR is only known after load_config runs, and the lock
# must be per-project or two projects would block each other.
boot_lock_dir() {
  printf '%s/localhost2cloud-%s.lock' "${TMPDIR:-/tmp}" "$(printf '%s' "$CFG_DIR" | cksum | cut -d' ' -f1)"
}

acquire_boot_lock() {
  local owner
  LOCK_DIR="$(boot_lock_dir)"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s' "$$" > "$LOCK_DIR/pid"
    BOOT_LOCK_HELD=1
    return 0
  fi
  owner="$(cat "$LOCK_DIR/pid" 2>/dev/null || echo '')"
  # A lock left behind by a dead process must not block forever.
  if [ -n "$owner" ] && ! pid_alive "$owner"; then
    warn "Clearing a stale boot lock (pid $owner is gone)"
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" 2>/dev/null || return 1
    printf '%s' "$$" > "$LOCK_DIR/pid"
    BOOT_LOCK_HELD=1
    return 0
  fi
  return 1
}

release_boot_lock() {
  [ "${BOOT_LOCK_HELD:-0}" = 1 ] || return 0
  rm -rf "${LOCK_DIR:-}" 2>/dev/null || true
  BOOT_LOCK_HELD=0
}

# ---------------------------------------------------------------------------
# Process management
# ---------------------------------------------------------------------------
# PIDs get recycled, especially on Linux where pid_max is often 32768. A stale
# session.json could therefore name a PID that now belongs to something else
# entirely - and we would kill it. That breaks our "never kill what it did not
# start" promise, so every recorded PID carries a fingerprint (its start time)
# and is verified before any signal is sent.

pid_alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

# proc_start <pid> -> stable identity string for that process, or empty.
# Works on Linux and macOS without /proc. Falls back to empty if unavailable,
# in which case the guard degrades to "process exists" rather than failing hard.
proc_start() {
  local pid="$1"
  [ -n "$pid" ] || return 1
  # -o lstart= gives e.g. "Tue Nov 11 18:30:36 2026" and is stable per process.
  ps -p "$pid" -o lstart= 2>/dev/null | sed 's/^ *//; s/ *$//'
}

# proc_fingerprint <pid> -> "pid|start". The start may be empty on exotic
# systems, in which case callers must treat identity as unverified.
proc_fingerprint() {
  local pid="$1" start
  start="$(proc_start "$pid")" || true
  printf '%s|%s' "$pid" "$start"
}

# proc_matches <pid> <recorded-start> -> 0 when this is still our process.
# Empty recorded start means legacy/unverifiable: accept existence only, but
# callers surface a warning so the degraded mode is visible, not silent.
proc_matches() {
  local pid="$1" want="$2" have
  pid_alive "$pid" || return 1
  [ -n "$want" ] || return 0
  have="$(proc_start "$pid")" || return 1
  [ "$have" = "$want" ]
}

# Kill a process and everything it spawned (Next spawns workers).
kill_tree() {
  local pid="$1" sig="${2:-TERM}" kid
  [ -n "$pid" ] || return 0
  pid_alive "$pid" || return 0
  if command -v pgrep >/dev/null 2>&1; then
    for kid in $(pgrep -P "$pid" 2>/dev/null); do
      kill_tree "$kid" "$sig"
    done
  fi
  kill -"$sig" "$pid" 2>/dev/null || true
}

kill_tree_force() {
  local pid="$1"
  [ -n "$pid" ] || return 0
  kill_tree "$pid" TERM
  local i=0
  while pid_alive "$pid" && [ "$i" -lt 20 ]; do sleep 0.25; i=$((i + 1)); done
  pid_alive "$pid" && kill_tree "$pid" KILL
  return 0
}

# start_logged <name> <workdir> <logdir> <cmd> [args...] -> prints "pid|start"
# nohup + background so the process outlives the script but stays killable.
start_logged() {
  local name="$1" workdir="$2" logdir="$3"; shift 3
  local out="$logdir/$name.out.log" err="$logdir/$name.err.log"
  mkdir -p "$logdir"
  : > "$out"; : > "$err"
  local pidfile="$logdir/.$name.pid"
  rm -f "$pidfile"
  (
    cd "$workdir" 2>/dev/null || exit 1
    nohup "$@" >"$out" 2>"$err" </dev/null &
    echo $! > "$pidfile"
  )
  [ -f "$pidfile" ] || return 1
  local pid; pid="$(cat "$pidfile")"
  # Give the child a moment so ps can resolve its start time.
  local i=0
  while [ -z "$(proc_start "$pid")" ] && [ "$i" -lt 10 ]; do sleep 0.1; i=$((i + 1)); done
  proc_fingerprint "$pid"
}

log_text() {
  local name="$1" logdir="$2"
  cat "$logdir/$name.out.log" "$logdir/$name.err.log" 2>/dev/null || true
}

# resolve_tool <name> [explicit path] [extra fallback dirs...] -> prints path
resolve_tool() {
  local name="$1" explicit="${2:-}"
  if [ -n "$explicit" ]; then
    [ -x "$explicit" ] || die "Not executable: $explicit"
    printf '%s' "$explicit"; return 0
  fi
  if command -v "$name" >/dev/null 2>&1; then
    command -v "$name"; return 0
  fi
  [ "$#" -gt 2 ] && shift 2
  local dir
  for dir in "$@"; do
    [ -x "$dir/$name" ] && { printf '%s' "$dir/$name"; return 0; }
  done
  die "'$name' not found. Install it (see install-tools.sh) or pass its path."
}

# ---------------------------------------------------------------------------
# Caddyfile generation
# ---------------------------------------------------------------------------
# Exactly one origin must front every port the browser touches: a single tunnel
# can only target one local address. Generated per boot so routes cannot drift.

generate_caddyfile() {
  local out="$1"
  local default_name='' default_port='' exposed=0 i prefix
  : > "$out"
  {
    echo '# GENERATED by localhost2cloud from demo.config.json - do not hand-edit.'
    echo '# Regenerated on every boot so the routes always match the config.'
    echo ''
    echo '{'
    printf '\tauto_https off\n'
    printf '\tadmin off\n'
    echo '}'
    echo ''
    echo ":$GW_PORT {"
    printf '\tencode zstd gzip\n'
    echo ''
  } >> "$out"

  i=0
  while [ "$i" -lt "$SVC_COUNT" ]; do
    local expose; expose="$(svc_var "$i" EXPOSE)"
    for prefix in $expose; do
      exposed=$((exposed + 1))
      {
        printf '\thandle %s {\n' "$prefix"
        printf '\t\treverse_proxy 127.0.0.1:%s {\n' "$(svc_var "$i" PORT)"
        printf '\t\t\theader_up X-Forwarded-Proto https\n'
        printf '\t\t}\n'
        printf '\t}\n\n'
      } >> "$out"
    done
    if [ "$(svc_var "$i" DEFAULT)" = true ]; then
      default_name="$(svc_var "$i" NAME)"
      default_port="$(svc_var "$i" PORT)"
    fi
    i=$((i + 1))
  done

  [ -n "$default_name" ] || \
    die 'Config needs exactly one service with "default": true to serve everything not matched by expose[].'

  {
    printf '\thandle {\n'
    printf '\t\treverse_proxy 127.0.0.1:%s {\n' "$default_port"
    printf '\t\t\theader_up X-Forwarded-Proto https\n'
    printf '\t\t}\n'
    printf '\t}\n'
    echo '}'
  } >> "$out"

  printf '%s|%s' "$exposed" "$default_name"
}
