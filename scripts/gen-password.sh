#!/usr/bin/env bash
# Generate a demo password and the matching Caddy hash, ready to paste into
# demo.config.json. Run with -c PATH to patch the config in place.
#
#   ./gen-password.sh                 # print a password + hash
#   ./gen-password.sh -c ../demo.config.json   # write auth{} into the config
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
. "$SCRIPT_DIR/common.sh"

CONFIG_PATH=''
LENGTH=24
USER_NAME='demo'
while [ "$#" -gt 0 ]; do
  case "$1" in
    -c|--config) CONFIG_PATH="${2:-}"; shift 2 ;;
    -u|--user)   USER_NAME="${2:-demo}"; shift 2 ;;
    -l|--length) LENGTH="${2:-24}"; shift 2 ;;
    -h|--help)   sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

CADDY_BIN="$(resolve_tool caddy '' /usr/local/bin /opt/homebrew/bin)" || exit 1

# Ambiguous characters (0/O, 1/l/I) omitted: this gets read aloud or retyped.
pw="$(LC_ALL=C tr -dc 'A-Za-z2-9' </dev/urandom | head -c "$LENGTH")"
[ -n "$pw" ] || die "Could not generate a password (is /dev/urandom readable?)"

hash="$("$CADDY_BIN" hash-password --plaintext "$pw")" || die "caddy hash-password failed"

if [ -z "$CONFIG_PATH" ]; then
  printf '\nAdd this to demo.config.json:\n\n'
  printf '  "auth": {\n'
  printf '    "enabled": true,\n'
  printf '    "username": "%s",\n' "$USER_NAME"
  printf '    "passwordHash": "%s"\n' "$hash"
  printf '  }\n\n'
  printf 'Password: %s\n' "$pw"
  printf '(the hash is what goes in the file; the password is what you share)\n\n'
  exit 0
fi

load_config "$CONFIG_PATH" || exit 1
python3 - "$CFG_PATH" "$USER_NAME" "$hash" <<'PY' || die "Config update failed (python3 required)"
import json, sys
path, user, hsh = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding='utf-8') as f:
    cfg = json.load(f)
cfg['auth'] = {'enabled': True, 'username': user, 'passwordHash': hsh}
with open(path, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')
print(f"wrote auth{{}} into {path}")
PY

printf '\nDone. Password: %s\n' "$pw"
printf 'Start the demo and that password will be required to open the link.\n\n'
