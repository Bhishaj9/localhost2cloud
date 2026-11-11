#!/usr/bin/env bash
# Show whether the demo and its public link are still alive.
#
# POSIX counterpart to Status-Demo.ps1. Checks each process, each local port,
# the gateway routing and the public URL end to end, then reprints the link so
# it can be re-shared without a reboot. Exit 0 when healthy, 1 otherwise.
#
# Usage:
#   ./status.sh [-c PATH]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
. "$SCRIPT_DIR/common.sh"

CONFIG_PATH=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -c|--config) CONFIG_PATH="${2:-}"; shift 2 ;;
    -h|--help)   sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
done

load_config "$CONFIG_PATH" || exit 1

if ! has_state; then
  warn "No demo running for $CFG_DIR. Run ./start.sh."
  exit 1
fi

healthy=1
step "Session started $(state_get 'StartedAt' 2>/dev/null || echo unknown) (provider: $(state_get 'Provider' 2>/dev/null || echo unknown))"
printf '\n'

check_pid() {
  local key="$1" label="$2" pid
  pid="$(state_get "Pids.$key" 2>/dev/null || true)"
  if [ -n "$pid" ]; then
    if pid_alive "$pid"; then
      printf '  %s%-12s running (pid %s)%s\n' "$C_GREEN" "$label" "$pid" "$C_RESET"
    else
      printf '  %s%-12s DOWN (was pid %s)%s\n' "$C_RED" "$label" "$pid" "$C_RESET"
      healthy=0
    fi
  else
    printf '  %s%-12s external (not started by the demo)%s\n' "$C_GREY" "$label" "$C_RESET"
  fi
}

check_pid tunnel tunnel
check_pid gateway gateway
i=0
while [ "$i" -lt "$SVC_COUNT" ]; do
  check_pid "$(svc_var "$i" NAME)" "$(svc_var "$i" NAME)"
  i=$((i + 1))
done

printf '\n'
step "Ports"
i=0
while [ "$i" -lt "$SVC_COUNT" ]; do
  name="$(svc_var "$i" NAME)"; port="$(svc_var "$i" PORT)"; hu="$(svc_var "$i" HEALTHURL)"
  if port_open "$port"; then
    if health_ok "$hu" 8 ''; then
      printf '  %s%-12s port %s open, health OK%s\n' "$C_GREEN" "$name" "$port" "$C_RESET"
    else
      printf '  %s%-12s port %s open, health FAILING%s\n' "$C_YELLOW" "$name" "$port" "$C_RESET"
      healthy=0
    fi
  else
    printf '  %s%-12s port %s CLOSED%s\n' "$C_RED" "$name" "$port" "$C_RESET"
    healthy=0
  fi
  i=$((i + 1))
done

printf '\n'
step "Gateway"
GW_BASE="http://127.0.0.1:$GW_PORT"
i=0
while [ "$i" -lt "$SVC_COUNT" ]; do
  name="$(svc_var "$i" NAME)"
  expose="$(svc_var "$i" EXPOSE)"
  if [ -n "$expose" ]; then
    vp="$(svc_var "$i" VERIFY)"
    probe="$GW_BASE$vp"
    if [ -z "$vp" ]; then
      set -- $expose
      probe="$GW_BASE$1"
    fi
    accepted="$(svc_var "$i" ACCEPT)"
    code="$(http_code "$probe" 10)"
    reachable=0
    case "$code" in 000) ;; 5??) ;; *) reachable=1 ;; esac
    for a in $accepted; do [ "$code" = "$a" ] && reachable=1; done
    if [ "$reachable" -eq 1 ]; then
      printf '  %s%s -> %s : HTTP %s%s\n' "$C_GREEN" "$expose" "$name" "$code" "$C_RESET"
    else
      printf '  %s%s -> %s : HTTP %s%s\n' "$C_YELLOW" "$expose" "$name" "$code" "$C_RESET"
      healthy=0
    fi
  elif [ "$(svc_var "$i" DEFAULT)" != 'true' ]; then
    printf '  %s%s : not routed through the gateway (local only on port %s)%s\n' \
      "$C_GREY" "$name" "$(svc_var "$i" PORT)" "$C_RESET"
  fi
  i=$((i + 1))
done

printf '\n'
step "Public URL"
url="$(state_get 'Url' 2>/dev/null || true)"
provider="$(state_get 'Provider' 2>/dev/null || true)"
if [ "$provider" = none ]; then
  grey "No tunnel (provider 'none'). Local address only:"
  printf '  %s%s%s\n' "$C_GREEN" "$url" "$C_RESET"
else
  code="$(http_code "$url/" 25)"
  case "$code" in
    2??|3??) printf '  %sPage: HTTP %s%s\n' "$C_GREEN" "$code" "$C_RESET" ;;
    *)       printf '  %sPage: HTTP %s%s\n' "$C_RED" "$code" "$C_RESET"; healthy=0 ;;
  esac
  printf '\n  %s%s%s\n' "$C_GREEN" "$url" "$C_RESET"
fi

printf '\n'
if [ "$healthy" -eq 1 ]; then
  printf '%sEverything checks out.%s\n' "$C_GREEN" "$C_RESET"
  exit 0
fi
printf '%sSomething is down. ./stop.sh then ./start.sh to rebuild.%s\n' "$C_YELLOW" "$C_RESET"
exit 1
