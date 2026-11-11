#!/usr/bin/env bash
# Close the public link and stop what the demo booted.
#
# POSIX counterpart to Stop-Demo.ps1. Kills the tunnel, the gateway and every
# service this skill started, using the recorded session file. Services that
# were already running before the boot were never owned by the skill and are
# left alone unless you pass --include-reused.
#
# Usage:
#   ./stop.sh [options]
#
# Options:
#   -c, --config PATH      Path to demo.config.json (default: auto-discover)
#       --include-reused   Also stop services that were already running
#       --keep-gateway     Leave the local gateway running
#   -h, --help             Show this help

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
. "$SCRIPT_DIR/common.sh"

CONFIG_PATH=''; INCLUDE_REUSED='false'; KEEP_GATEWAY='false'

while [ "$#" -gt 0 ]; do
  case "$1" in
    -c|--config)       CONFIG_PATH="${2:-}"; shift 2 ;;
    --include-reused)  INCLUDE_REUSED='true'; shift ;;
    --keep-gateway)    KEEP_GATEWAY='true'; shift ;;
    -h|--help)         sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
done

load_config "$CONFIG_PATH" || exit 1

if ! has_state; then
  step "No demo session recorded for $CFG_DIR"
  leftovers=''
  for n in cloudflared ngrok caddy; do
    if command -v pgrep >/dev/null 2>&1; then
      for p in $(pgrep -x "$n" 2>/dev/null || true); do
        leftovers="$leftovers $n(pid $p)"
      done
    fi
  done
  if [ -n "$leftovers" ]; then
    warn "These tunnel/gateway processes are still running and may not belong to a demo:$leftovers"
    warn "Stop them yourself if they are unwanted; this script will not guess."
  fi
  exit 0
fi

step "Closing the public link for $CFG_DIR"
old_url="$(state_get 'Url' 2>/dev/null || true)"
[ -n "$old_url" ] && ok "was: $old_url"
# Complete=false means the boot died before it finished (hard kill, closed
# terminal, reboot). The journal still names what started, so we can clean up.
if [ "$(state_get 'Complete' 2>/dev/null || true)" = 'false' ]; then
  warn "This session was interrupted before the demo finished starting - cleaning up a partial boot."
fi

stopped=0

stop_one() {
  local key="$1" label="$2" pid start
  pid="$(state_get "Pids.$key" 2>/dev/null || true)"
  start="$(state_get "Starts.$key" 2>/dev/null || true)"
  if [ -z "$pid" ]; then
    # A missing key means either "never started" (provider none, or reused) or
    # "reused, still running". Only say "left running" when something actually
    # holds the port, so a local-only session does not claim a phantom tunnel.
    if [ "$key" = tunnel ] || [ "$key" = gateway ]; then
      return 0
    fi
    ok "$label : left running (was already up before the demo)"
    return 0
  fi
  if ! pid_alive "$pid"; then
    ok "$label already gone (pid $pid)"
    return 0
  fi
  # The PID may have been recycled since boot. Killing a stranger's process
  # would break the core promise, so verify identity before signalling.
  if ! proc_matches "$pid" "$start"; then
    warn "$label : pid $pid now belongs to a different process (PID reused) - not touching it"
    return 0
  fi
  kill_tree_force "$pid"
  ok "$label stopped (pid $pid)"
  stopped=$((stopped + 1))
}

if [ "$KEEP_GATEWAY" != 'true' ]; then
  stop_one tunnel 'tunnel'
  stop_one gateway 'gateway'
else
  stop_one tunnel 'tunnel'
  ok "gateway : kept running (--keep-gateway)"
fi

i=0
while [ "$i" -lt "$SVC_COUNT" ]; do
  stop_one "$(svc_var "$i" NAME)" "$(svc_var "$i" NAME)"
  i=$((i + 1))
done

if [ "$INCLUDE_REUSED" = 'true' ]; then
  i=0
  while [ "$i" -lt "$SVC_COUNT" ]; do
    port="$(svc_var "$i" PORT)"
    owner="$(port_owner "$port" || true)"
    if [ -n "$owner" ]; then
      warn "'$(svc_var "$i" NAME)' still holding port $port: ${owner#*|} (pid ${owner%%|*})"
      grey "Stop it manually if it should go down - it predates this demo."
    fi
    i=$((i + 1))
  done
fi

clear_state

# A boot killed with -9 or a closed terminal cannot release its lock, which would
# block the next boot even with nothing running. Clear it when its owner is gone.
LOCK_DIR="$(boot_lock_dir)"
if [ -d "$LOCK_DIR" ]; then
  owner="$(cat "$LOCK_DIR/pid" 2>/dev/null || echo '')"
  if [ -z "$owner" ] || ! pid_alive "$owner"; then
    rm -rf "$LOCK_DIR" 2>/dev/null || true
    ok "cleared a stale boot lock"
  fi
fi

printf '\n'
printf '%sDemo closed. The public URL no longer resolves to this machine.%s\n' "$C_GREEN" "$C_RESET"
[ "$stopped" -eq 0 ] && grey "Nothing was running under this session."
exit 0
