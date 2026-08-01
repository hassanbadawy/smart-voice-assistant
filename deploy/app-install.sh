#!/usr/bin/env bash
# App-only install (NO models): Supertonic TTS + web UI. STT/LLM stay pointed at
# whatever you configure (Settings or SVA_*_ENDPOINT). Tests the app components.
#
#   ./app-install.sh [-n NAMESPACE]
set -euo pipefail
usage() { grep -E '^# ' "$0" | sed 's/^# //'; }
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
parse_args "$@"; resolve_ns
banner "App-only install → namespace: $NS"
deploy_supertonic
deploy_webui
wire_endpoints tts-only
run_component_tests || true
done_msg "App installed (models not included)"
