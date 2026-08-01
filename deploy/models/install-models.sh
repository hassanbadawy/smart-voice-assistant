#!/usr/bin/env bash
# Install the Whisper (STT) + Ministral (LLM) models on OpenShift via KServe.
# Models are pulled from the public Red Hat AI ModelCar catalog on quay.io
# (no S3 / pull secret needed). Requires: RHOAI/KServe + the NVIDIA GPU Operator
# and at least one schedulable GPU (one per model, 2 total by default).
#
# Usage:
#   ./install-models.sh [-n NAMESPACE] [--wire-webui]
#
#   --wire-webui   point the smart-voice-assistant ConfigMap at these models
#                  and restart it (run after the web UI is deployed).
set -euo pipefail

NAMESPACE=""
WIRE=0
HERE="$(cd "$(dirname "$0")" && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    --wire-webui) WIRE=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done
NS_FLAG=(); [[ -n "$NAMESPACE" ]] && NS_FLAG=(-n "$NAMESPACE")
NS="${NAMESPACE:-$(oc project -q)}"

echo "▶ Namespace: $NS"
echo "▶ Applying ServingRuntime + InferenceServices"
oc apply "${NS_FLAG[@]}" -f "$HERE/serving-runtime.yaml"
oc apply "${NS_FLAG[@]}" -f "$HERE/whisper-stt.yaml"
oc apply "${NS_FLAG[@]}" -f "$HERE/ministral-llm.yaml"

echo "▶ Waiting for models to become Ready (model pull can take several minutes)…"
oc wait --for=condition=Ready "${NS_FLAG[@]}" inferenceservice/whisper-large-v3        --timeout=900s
oc wait --for=condition=Ready "${NS_FLAG[@]}" inferenceservice/ministral-3-3b-instruct --timeout=900s

STT="http://whisper-large-v3-predictor.$NS.svc.cluster.local:8080/v1"
LLM="http://ministral-3-3b-instruct-predictor.$NS.svc.cluster.local:8080/v1"

echo ""
echo "✅ Models ready. Wire the web UI with:"
echo "     SVA_STT_MODEL=whisper-large-v3          SVA_STT_ENDPOINT=$STT"
echo "     SVA_LLM_MODEL=ministral-3-3b-instruct   SVA_LLM_ENDPOINT=$LLM"

if [[ "$WIRE" == "1" ]]; then
  echo "▶ Wiring smart-voice-assistant ConfigMap + restarting"
  oc set data "${NS_FLAG[@]}" configmap/smart-voice-assistant-config \
    SVA_STT_MODEL=whisper-large-v3 SVA_STT_ENDPOINT="$STT" \
    SVA_LLM_MODEL=ministral-3-3b-instruct SVA_LLM_ENDPOINT="$LLM"
  oc rollout restart "${NS_FLAG[@]}" deploy/smart-voice-assistant
fi
