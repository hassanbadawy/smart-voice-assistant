#!/usr/bin/env bash
# Shared functions for the Smart Voice Assistant install/uninstall scripts.
# Sourced by full-install.sh / app-install.sh / full-uninstall.sh / app-uninstall.sh.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# ---------- colours / progress ----------
if [ -t 1 ]; then
  BOLD=$'\e[1m'; DIM=$'\e[2m'; GRN=$'\e[32m'; RED=$'\e[31m'; YLW=$'\e[33m'; CYN=$'\e[36m'; RST=$'\e[0m'
else
  BOLD=; DIM=; GRN=; RED=; YLW=; CYN=; RST=
fi
banner() { printf "\n%s%s%s\n%s%s%s\n" "$BOLD$CYN" "$1" "$RST" "$DIM" "────────────────────────────────────────" "$RST"; }
step()   { printf "\n%s▶%s %s\n" "$BOLD" "$RST" "$1"; }
ok()     { printf "  %s✓%s %s\n" "$GRN" "$RST" "$1"; }
bad()    { printf "  %s✗%s %s\n" "$RED" "$RST" "$1"; }
skip()   { printf "  %s•%s %s\n" "$YLW" "$RST" "$DIM$1$RST"; }

# ---------- args ----------
NS_ARG=""
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -n|--namespace) NS_ARG="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "unknown arg: $1" >&2; usage; exit 1 ;;
    esac
  done
}
resolve_ns() {
  command -v oc >/dev/null || { bad "oc not found on PATH"; exit 1; }
  oc whoami >/dev/null 2>&1 || { bad "not logged in — run 'oc login ...' first"; exit 1; }
  NS="${NS_ARG:-$(oc project -q 2>/dev/null)}"
  [ -n "$NS" ] || { bad "no namespace (pass -n NAMESPACE)"; exit 1; }
}
route_url() { printf "https://%s" "$(oc get route smart-voice-assistant -n "$NS" -o jsonpath='{.spec.host}' 2>/dev/null)"; }

# ---------- models (STT + LLM) ----------
deploy_models() {
  step "Models — applying Whisper (STT) + Ministral (LLM) manifests"
  oc apply -n "$NS" -f "$HERE/models/serving-runtime.yaml" \
                    -f "$HERE/models/whisper-stt.yaml" \
                    -f "$HERE/models/ministral-llm.yaml" >/dev/null
  step "Models — waiting for Ready (weight pull can take several minutes)"
  if oc wait -n "$NS" --for=condition=Ready isvc/whisper-large-v3 --timeout=900s >/dev/null 2>&1; then
    ok "Whisper STT ready"; else bad "Whisper STT did not become Ready"; fi
  if oc wait -n "$NS" --for=condition=Ready isvc/ministral-3-3b-instruct --timeout=900s >/dev/null 2>&1; then
    ok "Ministral LLM ready"; else bad "Ministral LLM did not become Ready"; fi
}
uninstall_models() {
  step "Removing models (Whisper + Ministral + ServingRuntime)"
  oc delete -n "$NS" -f "$HERE/models/whisper-stt.yaml" \
                     -f "$HERE/models/ministral-llm.yaml" \
                     -f "$HERE/models/serving-runtime.yaml" --ignore-not-found
  ok "Models removed"
}

# ---------- app (Supertonic TTS + web UI) ----------
deploy_supertonic() {
  step "Supertonic (TTS) — build image on-cluster + deploy"
  oc apply -n "$NS" -f "$HERE/supertonic.yaml" >/dev/null
  oc start-build supertonic --from-dir="$ROOT/supertonic" --follow -n "$NS"
  oc rollout status deploy/supertonic -n "$NS" --timeout=180s
  ok "Supertonic deployed"
}
deploy_webui() {
  step "Web UI — build image on-cluster + deploy"
  oc apply -n "$NS" -f "$HERE/webui.yaml" >/dev/null
  oc start-build smart-voice-assistant --from-dir="$ROOT" --follow -n "$NS"
  oc rollout status deploy/smart-voice-assistant -n "$NS" --timeout=180s
  ok "Web UI deployed"
}
uninstall_app() {
  step "Removing web UI + Supertonic"
  oc delete -n "$NS" -f "$HERE/webui.yaml" --ignore-not-found
  oc delete -n "$NS" -f "$HERE/supertonic.yaml" --ignore-not-found
  ok "App removed"
}

# Wire the ConfigMap. wire_endpoints <all|tts-only>, then restart the UI.
wire_endpoints() {
  local mode="$1"
  step "Wiring endpoints (${mode}) + restarting web UI"
  if [ "$mode" = "all" ]; then
    oc set data -n "$NS" configmap/smart-voice-assistant-config \
      SVA_STT_MODEL=whisper-large-v3 \
      SVA_STT_ENDPOINT="http://whisper-large-v3-predictor.$NS.svc.cluster.local:8080/v1" \
      SVA_LLM_MODEL=ministral-3-3b-instruct \
      SVA_LLM_ENDPOINT="http://ministral-3-3b-instruct-predictor.$NS.svc.cluster.local:8080/v1" \
      SVA_TTS_ENDPOINT="http://supertonic.$NS.svc.cluster.local:7788/v1/tts" >/dev/null
  else
    oc set data -n "$NS" configmap/smart-voice-assistant-config \
      SVA_TTS_ENDPOINT="http://supertonic.$NS.svc.cluster.local:7788/v1/tts" >/dev/null
  fi
  oc rollout restart deploy/smart-voice-assistant -n "$NS" >/dev/null
  oc rollout status  deploy/smart-voice-assistant -n "$NS" --timeout=120s >/dev/null
  ok "Endpoints wired"
}

# ---------- component tests (through the public route) ----------
# Exercises every deployed component end-to-end from outside the cluster.
run_component_tests() {
  local url; url="$(route_url)"
  banner "Testing components"
  printf "  %sroute:%s %s\n" "$DIM" "$RST" "$url"

  # read the effective config (endpoints + model ids) from the app
  eval "$(curl -sk "$url/api/config" 2>/dev/null | python3 -c '
import sys,json
try: c=json.load(sys.stdin)["services"]
except Exception: c={"stt":{},"llm":{},"tts":{}}
def q(s): return "\x27"+str(s or "").replace("\x27","")+"\x27"
print("STT_EP="+q(c["stt"].get("endpoint")))
print("LLM_EP="+q(c["llm"].get("endpoint")))
print("STT_MODEL="+q(c["stt"].get("name")))
print("LLM_MODEL="+q(c["llm"].get("name")))
' 2>/dev/null)"

  local pass=0 failed=0 skipped=0
  local wav="/tmp/sva_test_$$.wav"; local have_wav=0

  # 1/4 Web UI
  printf "\n%s[1/4]%s Web UI            " "$BOLD" "$RST"
  if [ "$(curl -sk -o /dev/null -w '%{http_code}' "$url/api/health")" = "200" ]; then
    printf "%s✓%s  /api/health 200\n" "$GRN" "$RST"; pass=$((pass+1))
  else printf "%s✗%s  /api/health unreachable\n" "$RED" "$RST"; failed=$((failed+1)); fi

  # 2/4 TTS (Supertonic)
  printf "%s[2/4]%s TTS (Supertonic)  " "$BOLD" "$RST"
  local code; code="$(curl -sk -o "$wav" -w '%{http_code}' -X POST "$url/api/tts" \
    -H 'Content-Type: application/json' -d '{"text":"Component test.","lang":"en","voice":"M1"}')"
  if [ "$code" = "200" ] && [ -s "$wav" ]; then
    printf "%s✓%s  audio/wav, %s bytes\n" "$GRN" "$RST" "$(wc -c <"$wav" | tr -d ' ')"; pass=$((pass+1)); have_wav=1
  else printf "%s✗%s  /api/tts HTTP %s\n" "$RED" "$RST" "$code"; failed=$((failed+1)); fi

  # 3/4 LLM (Ministral)
  printf "%s[3/4]%s LLM (Ministral)   " "$BOLD" "$RST"
  if [ -z "${LLM_EP:-}" ]; then
    printf "%s•%s  skipped (no LLM endpoint configured)\n" "$YLW" "$RST"; skipped=$((skipped+1))
  else
    local reply; reply="$(curl -sk -X POST "$url/api/llm" -H 'Content-Type: application/json' \
      -d "{\"model\":\"${LLM_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in one word.\"}],\"max_tokens\":10}" \
      | python3 -c 'import sys,json;print(json.load(sys.stdin).get("choices",[{}])[0].get("message",{}).get("content","").strip())' 2>/dev/null)"
    if [ -n "$reply" ]; then printf "%s✓%s  \"%s\"\n" "$GRN" "$RST" "$reply"; pass=$((pass+1))
    else printf "%s✗%s  no reply\n" "$RED" "$RST"; failed=$((failed+1)); fi
  fi

  # 4/4 STT (Whisper) — round-trips the TTS clip back to text
  printf "%s[4/4]%s STT (Whisper)     " "$BOLD" "$RST"
  if [ -z "${STT_EP:-}" ]; then
    printf "%s•%s  skipped (no STT endpoint configured)\n" "$YLW" "$RST"; skipped=$((skipped+1))
  elif [ "$have_wav" != "1" ]; then
    printf "%s•%s  skipped (no TTS clip to transcribe)\n" "$YLW" "$RST"; skipped=$((skipped+1))
  else
    local text; text="$(curl -sk -X POST "$url/api/stt" \
      -F "file=@$wav;type=audio/wav" -F "model=${STT_MODEL}" -F "response_format=json" \
      | python3 -c 'import sys,json;print(json.load(sys.stdin).get("text","").strip())' 2>/dev/null)"
    if [ -n "$text" ]; then printf "%s✓%s  \"%s\"\n" "$GRN" "$RST" "$text"; pass=$((pass+1))
    else printf "%s✗%s  no transcript\n" "$RED" "$RST"; failed=$((failed+1)); fi
  fi

  rm -f "$wav"
  printf "\n%s%d passed%s, %s%d skipped%s, %s%d failed%s\n" \
    "$GRN" "$pass" "$RST" "$YLW" "$skipped" "$RST" "$RED" "$failed" "$RST"
  [ "$failed" -eq 0 ]
}

done_msg() { printf "\n%s✅ %s%s\n   %s\n" "$BOLD$GRN" "$1" "$RST" "$(route_url)"; }
