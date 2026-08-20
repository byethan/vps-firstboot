#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN_SCRIPT="$SCRIPT_DIR/vps-firstboot.sh"
SOURCE_URL="${VPS_FIRSTBOOT_SOURCE_URL:-https://raw.githubusercontent.com/byethan/vps-firstboot/main/vps-firstboot.sh}"

if [[ -r "$MAIN_SCRIPT" ]]; then
  exec bash "$MAIN_SCRIPT" security "$@"
fi

tmp_script="$(mktemp)"
trap 'rm -f "$tmp_script"' EXIT

if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$SOURCE_URL" -o "$tmp_script"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "$tmp_script" "$SOURCE_URL"
else
  printf 'ERROR: curl or wget is required to download vps-firstboot.sh\n' >&2
  exit 1
fi

bash "$tmp_script" security "$@"
