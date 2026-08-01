#!/usr/bin/env bash
# One-shot status of the Smart Voice Assistant install (models + TTS + web UI).
# Watch a running install, or cron it every 5 minutes:
#   */5 * * * * /path/to/deploy/status.sh -n voice-assistant >> /tmp/sva-status.log 2>&1
#
#   ./status.sh [-n NAMESPACE]
set -euo pipefail
usage() { grep -E '^# ' "$0" | sed 's/^# //'; }
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
parse_args "$@"; resolve_ns
banner "Install status → $NS"
status_snapshot
url="$(route_url)"
if [ -n "${url#https://}" ]; then
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 "$url/api/health" 2>/dev/null || echo n/a)"
  printf "\n   route: %s  (health %s)\n" "$url" "$code"
else
  printf "\n   route: (web UI not deployed yet)\n"
fi
