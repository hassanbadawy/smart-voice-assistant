#!/usr/bin/env bash
# Full install: STT + LLM models, Supertonic TTS, and the web UI — then test
# every component through the public route and print the URL.
#
#   ./full-install.sh [-n NAMESPACE]
set -euo pipefail
usage() { grep -E '^# ' "$0" | sed 's/^# //'; }
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
parse_args "$@"; resolve_ns
banner "Full install → namespace: $NS"
ensure_namespace
preflight models
deploy_models
deploy_supertonic
deploy_webui
wire_endpoints all
if run_component_tests; then PASS=1; else PASS=0; fi
finalize "$PASS"
