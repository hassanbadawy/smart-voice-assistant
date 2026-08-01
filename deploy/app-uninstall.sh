#!/usr/bin/env bash
# App-only uninstall: remove the web UI + Supertonic, LEAVE the models running.
#
#   ./app-uninstall.sh [-n NAMESPACE]
set -euo pipefail
usage() { grep -E '^# ' "$0" | sed 's/^# //'; }
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
parse_args "$@"; resolve_ns
banner "App-only uninstall → namespace: $NS"
uninstall_app
printf "\n%s✅ App removed from %s (models left running)%s\n" "$BOLD$GRN" "$NS" "$RST"
