#!/usr/bin/env bash
# Deploy Smart Voice Assistant (+ optional Supertonic TTS) to OpenShift.
#
# Usage:
#   ./deploy.sh [-n NAMESPACE] [--no-supertonic]
#
# Requires: oc (logged in). Builds happen on-cluster from local source, so no
# local podman/registry is needed.
set -euo pipefail

NAMESPACE=""
DEPLOY_SUPERTONIC=1
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    --no-supertonic) DEPLOY_SUPERTONIC=0; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

NS_FLAG=()
[[ -n "$NAMESPACE" ]] && NS_FLAG=(-n "$NAMESPACE")

echo "▶ Target namespace: ${NAMESPACE:-$(oc project -q)}"

if [[ "$DEPLOY_SUPERTONIC" == "1" ]]; then
  echo "▶ Supertonic (TTS) — build + deploy"
  oc apply "${NS_FLAG[@]}" -f "$HERE/supertonic.yaml"
  oc start-build supertonic --from-dir="$ROOT/supertonic" --follow "${NS_FLAG[@]}"
  oc rollout status deploy/supertonic "${NS_FLAG[@]}" --timeout=180s
fi

echo "▶ Web UI — build + deploy"
oc apply "${NS_FLAG[@]}" -f "$HERE/webui.yaml"
oc start-build smart-voice-assistant --from-dir="$ROOT" --follow "${NS_FLAG[@]}"
oc rollout status deploy/smart-voice-assistant "${NS_FLAG[@]}" --timeout=180s

URL="https://$(oc get route smart-voice-assistant "${NS_FLAG[@]}" -o jsonpath='{.spec.host}')"
echo ""
echo "✅ Deployed:  $URL"
