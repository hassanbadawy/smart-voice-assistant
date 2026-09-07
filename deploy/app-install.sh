#!/usr/bin/env bash
# App-only install (NO models): Supertonic TTS + web UI. STT/LLM stay pointed at
# whatever you configure (Settings or SVA_*_ENDPOINT). Tests the app components.
#
# Deploys to the active 'oc project' (or -n NAMESPACE). The namespace must
# already exist. Only namespace-admin permissions are required.
#
# By default the web UI and TTS images are PULLED prebuilt from
# quay.io/hasan_badawy_ai — no internal image registry or on-cluster build
# needed. Pass --build to build them on-cluster from this checkout instead
# (required to deploy local code changes), or --registry to pull from elsewhere.
#
# Optional env vars:
#   SVA_WEBUI_IMAGE      prebuilt web UI image (skips on-cluster build)
#   SVA_TTS_IMAGE        prebuilt TTS image (skips on-cluster build)
#   SVA_DEFAULT_REGISTRY default registry to pull from (default quay.io/hasan_badawy_ai)
#
#   ./app-install.sh [-n NAMESPACE] [--build] [--registry REPO]
set -euo pipefail
usage() { grep -E '^# ' "$0" | sed 's/^# //'; }
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
parse_args "$@"; resolve_ns
banner "App-only install → namespace: $NS"
ensure_namespace
preflight
deploy_all
wire_endpoints tts-only
if run_component_tests; then PASS=1; else PASS=0; fi
finalize "$PASS"
