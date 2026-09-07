#!/usr/bin/env bash
# Full install: STT + LLM models, Supertonic TTS, and the web UI — then test
# every component through the public route and print the URL.
#
# Deploys to the active 'oc project' (or -n NAMESPACE). The namespace must
# already exist. Only namespace-admin permissions are required.
#
# Prerequisites: KServe/RHOAI installed, GPUs available, cluster pull-secret
# configured for registry.redhat.io.
#
# Optional env vars:
#   SVA_VLLM_IMAGE       vLLM runtime image (skips cross-namespace template lookup)
#   SVA_GPU_TAINT_KEYS   space-separated GPU node taint keys for tolerations
#   SVA_WEBUI_IMAGE      prebuilt web UI image (skips on-cluster build)
#   SVA_TTS_IMAGE        prebuilt TTS image (skips on-cluster build)
#
#   ./full-install.sh [-n NAMESPACE]
set -euo pipefail
usage() { grep -E '^# ' "$0" | sed 's/^# //'; }
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
parse_args "$@"; resolve_ns
banner "Full install → namespace: $NS"
ensure_namespace
preflight models
deploy_all models
wire_endpoints all
if run_component_tests; then PASS=1; else PASS=0; fi
finalize "$PASS"
