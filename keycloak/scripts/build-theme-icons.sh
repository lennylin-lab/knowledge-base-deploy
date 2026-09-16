#!/usr/bin/env bash
# Generate theme favicons from assets/favicon.svg (for local theme volume mounts).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGIN_OUT="${ROOT}/themes/kb/login/resources/img"
ADMIN_OUT="${ROOT}/themes/kb/admin/resources"
SRC="${ROOT}/assets/favicon.svg"

mkdir -p "$LOGIN_OUT" "$ADMIN_OUT"
cp "$SRC" "${LOGIN_OUT}/favicon.svg"
cp "$SRC" "${ADMIN_OUT}/favicon.svg"
magick -background none "$SRC" -define icon:auto-resize=64,48,32,16 "${LOGIN_OUT}/favicon.ico"
echo "Wrote login favicon: ${LOGIN_OUT}/favicon.ico"
echo "Wrote admin favicon:  ${ADMIN_OUT}/favicon.svg"
