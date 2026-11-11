#!/usr/bin/env bash
# Boot any local app stack and print ONE public link to share.
#
# POSIX counterpart to Start-Demo.ps1. Reads demo.config.json from the current
# directory or any parent, starts every declared service that is not already
# running, generates a Caddy gateway that puts them all behind ONE local origin,
# then opens a tunnel to that origin.
#
# Usage:
#   ./start.sh [options]
#
# Options:
#   -c, --config PATH     Path to demo.config.json (default: auto-discover)
#   -p, --provider NAME   cloudflare (default) | ngrok | none
#   -d, --dev             Use each service's devMode args
#   -f, --force           Tear down a stale session and boot fresh
#       --cloudflared P   Explicit path to cloudflared
#       --ngrok P         Explicit path to ngrok
#       --caddy P         Explicit path to caddy
#   -h, --help            Show this help

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
. "$SCRIPT_DIR/common.sh"

CONFIG_PATH=''; PROVIDER='cloudflare'; DEVMODE='false'; FORCE='false'
CLOUDFLARED_PATH=''; NGROK_PATH=''; CADDY_PATH=''

while [ "$#" -gt 0 ]; do
  case "$1" in
    -c|--config)     CONFIG_PATH="${2:-}"; shift 2 ;;
    -p|--provider)   PROVIDER="${2:-}"; shift 2 ;;
    -d|--dev)        DEVMODE='true'; shift ;;
    -f|--force)      FORCE='true'; shift ;;
    --cloudflared)   CLOUDFLARED_PATH="${2:-}"; shift 2 ;;
    --ngrok)         NGROK_PATH="${2:-}"; shift 2 ;;
    --caddy)         CADDY_PATH="${2:-}"; shift 2 ;;
    -h|--help)       sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
done

case "$PROVIDER" in cloudflare|ngrok|none) ;; *) die "Unknown provider: $PROVIDER" ;; esac

load_config "$CONFIG_PATH" || exit 1
step "Project: $CFG_DIR"

# --- 0. Existing session ---------------------------------------------------
if has_state && [ "$FORCE" != 'true' ]; then
  old_pid="$(state_get 'Pids.tunnel' 2>/dev/null || true)"
  if [ -n "$old_pid" ] && pid_alive "$old_pid"; then
    bad "A demo is already running for this project."
    printf '    URL: %s%s%s\n' "$C_GREEN" "$(state_get 'Url')" "$C_RESET"
    warn "Re-run with -f/--force to restart, or run ./stop.sh first."
    exit 0
  fi
  warn "Found a stale session record; cleaning it up"
  clear_state
fi

# --- 1. Tools --------------------------------------------------------------
step "Resolving tools"
CADDY="$(resolve_tool caddy "$CADDY_PATH" /usr/local/bin /opt/homebrew/bin)"
ok "caddy: $CADDY"

TUNNEL_EXE=''
case "$PROVIDER" in
  cloudflare) TUNNEL_EXE="$(resolve_tool cloudflared "$CLOUDFLARED_PATH" /usr/local/bin /opt/homebrew/bin)"
              ok "cloudflared: $TUNNEL_EXE" ;;
  ngrok)      TUNNEL_EXE="$(resolve_tool ngrok "$NGROK_PATH" /usr/local/bin /opt/homebrew/bin)"
              ok "ngrok: $TUNNEL_EXE" ;;
  none)       ok "provider 'none' - gateway only, reachable on this machine" ;;
esac

if [ "$PROVIDER" != none ] && ! command -v curl >/dev/null 2>&1; then
  die "curl is required to verify the public URL."
fi

LOGDIR="$(state_dir)"
PIDS=()

# --- 2. Services -----------------------------------------------------------
i=0
while [ "$i" -lt "$SVC_COUNT" ]; do
  name="$(svc_var "$i" NAME)"; port="$(svc_var "$i" PORT)"
  step "Service '$name' on port $port"

  if port_open "$port"; then
    owner="$(port_owner "$port" || true)"
    if wait_health "$(svc_var "$i" HEALTHURL)" 20 "'$name'"; then
      if [ -n "$owner" ]; then ok "Already running and healthy (pid ${owner%%|*}) - reusing"
      else ok "Already running and healthy - reusing"; fi
      PIDS+=("$name=")
      i=$((i + 1)); continue
    fi
    who='an unknown process'
    [ -n "$owner" ] && who="$(printf '%s' "${owner#*|}") (pid ${owner%%|*})"
    die "Port $port is held by $who but $(svc_var "$i" HEALTHURL) is not responding. Stop that process first - the skill will not kill something it did not start."
  fi

  if [ "$(svc_var "$i" MANAGED)" = false ]; then
    die "Service '$name' is not running on port $port and is marked managed:false (the skill will not start it). Start it yourself, then re-run."
  fi

  cmd="$(svc_var "$i" COMMAND)"
  [ -n "$cmd" ] || die "Service '$name' has no command[] and is not running."
  cmd="$(command -v "$cmd" 2>/dev/null || printf '%s' "$cmd")"

  workdir="$(service_dir "$i")"
  [ -d "$workdir" ] || die "Service '$name' working dir does not exist: $workdir"

  start_spec="$(svc_var "$i" START)"
  if [ "$DEVMODE" = 'true' ] && [ -n "$(svc_var "$i" DEVSTART)" ]; then
    start_spec="$(svc_var "$i" DEVSTART)"
  fi

  # Build before a production start. buildArgs without buildCommand is a
  # mistake, not a no-op - otherwise a stale bundle gets demoed silently.
  build_cmd="$(svc_var "$i" BUILD)"
  build_args_spec="$(svc_var "$i" BUILDARGS)"
  if [ "$DEVMODE" = 'true' ]; then
    :
  elif [ -n "$build_cmd" ]; then
    ok "Building: $build_cmd $(printf '%s' "$build_args_spec" | tr '\n' ' ')"
    build_argv=()
    while IFS= read -r a; do [ -n "$a" ] && build_argv+=("$a"); done <<EOF
$build_args_spec
EOF
    ( cd "$workdir" && "$build_cmd" ${build_argv[@]+"${build_argv[@]}"} ) || \
      die "Build failed for '$name'."
    ok "Build OK"
  elif [ -n "$build_args_spec" ]; then
    die "Service '$name' declares buildArgs but no buildCommand. Set buildCommand to the executable that runs the build."
  fi

  argv=()
  while IFS= read -r a; do [ -n "$a" ] && argv+=("$a"); done <<EOF
$start_spec
EOF

  pid="$(start_logged "$name" "$workdir" "$LOGDIR" "$cmd" ${argv[@]+"${argv[@]}"})" || \
    die "Could not start '$name'."
  PIDS+=("$name=$pid")
  ok "Started (pid $pid)"

  if ! wait_health "$(svc_var "$i" HEALTHURL)" 150 "'$name'"; then
    bad "Log tail:"
    log_text "$name" "$LOGDIR" | tail -n 25 | while IFS= read -r l; do grey "$l"; done
    die "Service '$name' did not become ready."
  fi
  ok "Ready"
  i=$((i + 1))
done

# --- 3. Gateway ------------------------------------------------------------
step "Gateway on port $GW_PORT"
if port_open "$GW_PORT"; then
  owner="$(port_owner "$GW_PORT" || true)"
  extra=''
  [ -n "$owner" ] && extra=" by ${owner#*|} (pid ${owner%%|*})"
  die "Port $GW_PORT is already in use$extra. Change gateway.port in demo.config.json."
fi

CADDYFILE="$LOGDIR/Caddyfile.generated"
gw_info="$(generate_caddyfile "$CADDYFILE")" || exit 1
ok "Routes: ${gw_info%%|*} prefix(es) -> services, default -> '${gw_info#*|}'"

gw_pid="$(start_logged gateway "$CFG_DIR" "$LOGDIR" "$CADDY" run --config "$CADDYFILE" --adapter caddyfile)" || \
  die "Could not start the gateway."
PIDS+=("gateway=$gw_pid")
ok "Started (pid $gw_pid)"

if ! wait_health "http://127.0.0.1:$GW_PORT/" 30 'the gateway'; then
  log_text gateway "$LOGDIR" | tail -n 25 | while IFS= read -r l; do grey "$l"; done
  die "Gateway did not come up."
fi
ok "Ready"

# --- 4. Tunnel -------------------------------------------------------------
PUBLIC_URL=''; TUNNEL_PID=''
if [ "$PROVIDER" = none ]; then
  step "No tunnel requested"
  PUBLIC_URL="http://127.0.0.1:$GW_PORT"
  ok "Local only: $PUBLIC_URL"
else
  step "Opening $PROVIDER tunnel"
  target="http://127.0.0.1:$GW_PORT"
  if [ "$PROVIDER" = cloudflare ]; then
    tun_pid="$(start_logged tunnel "$CFG_DIR" "$LOGDIR" "$TUNNEL_EXE" tunnel --url "$target" --no-autoupdate)" || \
      die "Could not start cloudflared."
    url_pattern='https://[a-z0-9-]+\.trycloudflare\.com'
  else
    tun_pid="$(start_logged tunnel "$CFG_DIR" "$LOGDIR" "$TUNNEL_EXE" http "$target" --log stdout)" || \
      die "Could not start ngrok."
    url_pattern='https://[a-z0-9-]+\.ngrok-free\.(app|dev)'
  fi
  TUNNEL_PID="$tun_pid"
  PIDS+=("tunnel=$tun_pid")

  deadline=$(( $(date +%s) + 100 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 0.6
    txt="$(log_text tunnel "$LOGDIR")"
    PUBLIC_URL="$(printf '%s\n' "$txt" | grep -oE "$url_pattern" | head -n1 || true)"
    [ -n "$PUBLIC_URL" ] && break
    if ! pid_alive "$tun_pid"; then
      log_text tunnel "$LOGDIR" | tail -n 20 | while IFS= read -r l; do grey "$l"; done
      die "The tunnel process exited before printing a URL."
    fi
  done
  if [ -z "$PUBLIC_URL" ]; then
    log_text tunnel "$LOGDIR" | tail -n 20 | while IFS= read -r l; do grey "$l"; done
    die "Could not read the public URL from the tunnel log."
  fi
  ok "$PUBLIC_URL"
fi

# --- 5. Verify from outside ------------------------------------------------
step "Verifying from outside this machine"
ALL_OK='true'
i=0
while [ "$i" -lt "$SVC_COUNT" ]; do
  hu="$(svc_var "$i" HEALTHURL)"
  if [ -n "$hu" ]; then
    path="${hu#*://}"; path="/${path#*/}"
    [ "$path" = "/" ] && path='/'
    vp="$(svc_var "$i" VERIFY)"
    [ -n "$vp" ] && path="$vp"
    url="$PUBLIC_URL$path"
    accepted="$(svc_var "$i" ACCEPT)"
    okk='false'
    n=1
    # Quick tunnels need DNS to propagate at the Cloudflare edge; a fresh
    # hostname can take ~40-75s before the first request is served. Budget for
    # that instead of reporting a false failure on a working link.
    while [ "$n" -le 15 ]; do
      if health_ok "$url" 20 "$accepted"; then okk='true'; break; fi
      sleep 5
      n=$((n + 1))
    done
    if [ "$okk" = 'true' ]; then ok "$(svc_var "$i" NAME) $path"
    else warn "$(svc_var "$i" NAME) $path (not answering yet)"; ALL_OK='false'; fi
  fi
  i=$((i + 1))
done

# --- 6. Save + report ------------------------------------------------------
save_state "$PUBLIC_URL" "$PROVIDER" "$DEVMODE" ${PIDS[@]+"${PIDS[@]}"}

printf '\n'
printf '%s%s%s\n' "$C_GREY" "======================================================================" "$C_RESET"
printf '  %sSHARE THIS LINK%s\n' "$C_CYAN" "$C_RESET"
printf '\n'
printf '  %s%s%s\n' "$C_GREEN" "$PUBLIC_URL" "$C_RESET"
printf '\n'
printf '%s%s%s\n' "$C_GREY" "======================================================================" "$C_RESET"
if [ "$ALL_OK" = 'true' ]; then
  printf '  %sAll checks passed from the public internet.%s\n' "$C_GREEN" "$C_RESET"
else
  printf '  %sSome checks failed - run ./status.sh for detail.%s\n' "$C_YELLOW" "$C_RESET"
fi
printf '%s  Anyone with the link can open it. Share it only with the demo audience.%s\n' "$C_GREY" "$C_RESET"
printf '%s  When they are done:  ./stop.sh%s\n' "$C_GREY" "$C_RESET"

if [ -n "${NOTES:-}" ]; then
  printf '\n'
  printf '%s\n' "$NOTES" | while IFS= read -r n; do
    [ -n "$n" ] && printf '%s  note: %s%s\n' "$C_GREY" "$n" "$C_RESET"
  done
fi
i=0
while [ "$i" -lt "$SVC_COUNT" ]; do
  nt="$(svc_var "$i" NOTE)"
  [ -n "$nt" ] && printf '%s  note: %s%s\n' "$C_GREY" "$nt" "$C_RESET"
  i=$((i + 1))
done
printf '\n'
