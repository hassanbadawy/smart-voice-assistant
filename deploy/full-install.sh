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
deploy_models
deploy_supertonic
deploy_webui
wire_endpoints all
run_component_tests || true
done_msg "Installed"
