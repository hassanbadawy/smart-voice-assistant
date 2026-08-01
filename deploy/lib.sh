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
ASSUME_YES=0
FORCE=0
MODEL_TIMEOUT="${MODEL_TIMEOUT:-900}"
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -n|--namespace) NS_ARG="$2"; shift 2 ;;
      -y|--yes) ASSUME_YES=1; shift ;;
      -f|--force) FORCE=1; shift ;;
      --timeout) MODEL_TIMEOUT="$2"; shift 2 ;;
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
ensure_namespace() {
  if ! oc get ns "$NS" >/dev/null 2>&1; then
    step "Creating namespace $NS"
    oc create namespace "$NS" >/dev/null && ok "namespace $NS created"
  fi
}
confirm() {  # $1 = prompt; honours --yes and non-interactive
  [ "$ASSUME_YES" = 1 ] && return 0
  if [ ! -t 0 ]; then skip "non-interactive — continuing"; return 0; fi
  printf "  %s%s [y/N]%s " "$YLW" "$1" "$RST"; read -r a
  case "$a" in y|Y|yes) return 0 ;; *) echo "  Aborted."; exit 1 ;; esac
}
route_url() { printf "https://%s" "$(oc get route smart-voice-assistant -n "$NS" -o jsonpath='{.spec.host}' 2>/dev/null || true)"; }

# ---------- preflight ----------
# GPU taint keys found on GPU nodes (space-separated) → deploy_models tolerates them.
GPU_TAINT_KEYS=""
GPU_TOTAL=0
GPU_SCHED=0
detect_gpu_taints() {
  local out
  out="$(oc get nodes -o json 2>/dev/null | python3 -c '
import sys,json
d=json.load(sys.stdin)
total=0; keys=set()
for n in d.get("items",[]):
    g=n.get("status",{}).get("allocatable",{}).get("nvidia.com/gpu")
    if not g: continue
    total+=int(g)
    for t in n.get("spec",{}).get("taints",[]):
        if t.get("effect") in ("NoSchedule","NoExecute") and t.get("key"):
            keys.add(t["key"])
joined=" ".join(sorted(keys))
print(str(total)+"|"+joined)
' 2>/dev/null || true)"
  GPU_TOTAL="${out%%|*}"; GPU_TAINT_KEYS="${out#*|}"
  GPU_TOTAL="${GPU_TOTAL:-0}"
  # every detected taint gets a toleration, so all allocatable GPUs are schedulable
  GPU_SCHED="$GPU_TOTAL"
}

# Consolidated preflight. `preflight models` adds RHOAI + GPU checks.
preflight() {
  local for_models="${1:-}"
  step "Preflight checks"

  # registry.redhat.io pull access (UBI base images + vLLM runtime)
  local ps
  ps="$(oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  if [ -n "$ps" ]; then
    echo "$ps" | grep -q 'registry.redhat.io' \
      && ok "registry.redhat.io pull access present" \
      || bad "registry.redhat.io missing from the cluster pull secret — Red Hat images will fail to pull"
  else
    skip "can't read openshift-config/pull-secret (need cluster-admin) — skipping pull-secret check"
  fi

  if [ "$for_models" = "models" ]; then
    if oc get crd inferenceservices.serving.kserve.io servingruntimes.serving.kserve.io >/dev/null 2>&1; then
      ok "KServe CRDs present (RHOAI/KServe installed)"
    else
      bad "KServe CRDs not found — RHOAI/KServe is required for the models"
      confirm "Continue without RHOAI (models will fail)?"
    fi
    if oc get template vllm-cuda-runtime-template -n redhat-ods-applications >/dev/null 2>&1; then
      ok "vLLM runtime template found (correct image auto-detected)"
    else
      bad "vllm-cuda-runtime-template not found — serving-runtime.yaml's image may not match this cluster's GPU driver (CUDA error 803)"
    fi
    detect_gpu_taints
    if [ "${GPU_TOTAL:-0}" -ge 2 ] 2>/dev/null; then
      ok "GPU: $GPU_TOTAL allocatable (need 2)${GPU_TAINT_KEYS:+; will tolerate taint(s): $GPU_TAINT_KEYS}"
    else
      bad "Only ${GPU_TOTAL:-0} GPU(s) allocatable — need 2 (one per model). Models will stay Pending."
      oc get csv -A 2>/dev/null | grep -qiE 'gpu-operator' \
        && skip "GPU Operator installed but not enough allocatable GPUs (no/small GPU MachineSet?)." \
        || skip "NVIDIA GPU Operator not detected — install it + a GPU MachineSet."
      confirm "Continue anyway (models will wait for a GPU)?"
    fi
  fi
}

# ---------- status snapshot + 5-minute monitor ----------
status_snapshot() {
  printf "%s┈┈ install status @ %s ┈┈%s\n" "$DIM" "$(date +%H:%M:%S)" "$RST"
  local isvc ready pod phase reason d rd
  for isvc in whisper-large-v3 ministral-3-3b-instruct; do
    oc get isvc "$isvc" -n "$NS" >/dev/null 2>&1 || continue
    ready="$(oc get isvc "$isvc" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    pod="$(oc get pods -n "$NS" -l serving.kserve.io/inferenceservice="$isvc" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [ -n "$pod" ]; then
      phase="$(oc get pod "$pod" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
      reason="$(oc get pod "$pod" -n "$NS" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}{.status.conditions[?(@.type=="PodScheduled")].reason}' 2>/dev/null || true)"
    else phase="no-pod"; reason="pending scheduling"; fi
    printf "   %-26s ready=%-6s pod=%-11s %s\n" "$isvc" "${ready:-?}" "${phase:-?}" "$reason"
  done
  for d in supertonic smart-voice-assistant; do
    oc get deploy "$d" -n "$NS" >/dev/null 2>&1 || continue
    rd="$(oc get deploy "$d" -n "$NS" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null || true)"
    printf "   %-26s ready=%s\n" "$d" "${rd:-0/0}"
  done
}
MONITOR_PID=""
start_monitor() {  # prints a snapshot now, then every 5 minutes until stopped
  ( status_snapshot; while true; do sleep 300; status_snapshot; done ) &
  MONITOR_PID=$!
}
stop_monitor() { [ -n "$MONITOR_PID" ] && kill "$MONITOR_PID" >/dev/null 2>&1; MONITOR_PID=""; }

# Print WHY a model isn't Ready (scheduling msg, or crash reason + last error log).
diagnose_model() {
  local isvc="$1" pod sched reason logline
  pod="$(oc get pods -n "$NS" -l serving.kserve.io/inferenceservice="$isvc" -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true)"
  [ -n "$pod" ] || { bad "$isvc: no pod created"; return; }
  sched="$(oc get pod "$pod" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].message}' 2>/dev/null || true)"
  [ -n "$sched" ] && { bad "$isvc: unschedulable — $sched"; return; }
  reason="$(oc get pod "$pod" -n "$NS" -o jsonpath='{.status.containerStatuses[?(@.name=="kserve-container")].state.waiting.reason}' 2>/dev/null || true)"
  logline="$(oc logs "$pod" -n "$NS" -c kserve-container --tail=60 --previous 2>/dev/null \
    | grep -iE 'error|exception|failed|keyerror|runtimeerror|cuda|unsupported|unrecogniz' \
    | grep -viE 'pid=|INFO|WARNING' | tail -1 || true)"
  [ -z "$logline" ] && logline="$(oc logs "$pod" -n "$NS" -c kserve-container --tail=3 2>/dev/null | tail -1 || true)"
  bad "$isvc: ${reason:-not ready} — ${logline:-<no error captured yet>}"
}

# Wait for both models Ready. Returns early (non-zero) with a diagnosis on
# crash-loop or timeout, instead of blocking blindly.
wait_models() {
  local deadline=$(( $(date +%s) + MODEL_TIMEOUT )) m rc
  while :; do
    local wr mr; wr=""; mr=""
    wr="$(oc get isvc whisper-large-v3        -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    mr="$(oc get isvc ministral-3-3b-instruct -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    [ "$wr" = "True" ] && [ "$mr" = "True" ] && return 0
    local crashed=""
    for m in whisper-large-v3 ministral-3-3b-instruct; do
      rc="$(oc get pods -n "$NS" -l serving.kserve.io/inferenceservice="$m" -o jsonpath='{.items[-1:].status.containerStatuses[?(@.name=="kserve-container")].restartCount}' 2>/dev/null || true)"
      [ "${rc:-0}" -ge 3 ] 2>/dev/null && crashed="$crashed $m"
    done
    if [ -n "$crashed" ]; then
      bad "Model(s) crash-looping —$crashed:"; for m in $crashed; do diagnose_model "$m"; done; return 1
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      bad "Timed out after ${MODEL_TIMEOUT}s waiting for models:"
      diagnose_model whisper-large-v3; diagnose_model ministral-3-3b-instruct; return 1
    fi
    sleep 15
  done
}

# ---------- models (STT + LLM) ----------
deploy_models() {
  # Per-model: keep any model that's already Ready (a re-pull is slow and yields
  # the same result). --force redeploys regardless.
  local m ready todo=()
  for m in whisper-large-v3 ministral-3-3b-instruct; do
    ready="$(oc get isvc "$m" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    if [ "$ready" = "True" ] && [ "$FORCE" != "1" ]; then
      ok "$m already Ready — keeping it (use --force to re-pull)"
    else
      todo+=("$m")
    fi
  done
  if [ "${#todo[@]}" -eq 0 ]; then ok "Both models already Ready — nothing to do"; return 0; fi

  # Correct vLLM image for THIS cluster (avoids CUDA-803 / unknown-arch crashes).
  local vllm_img
  vllm_img="$(oc get template vllm-cuda-runtime-template -n redhat-ods-applications -o jsonpath='{.objects[0].spec.containers[0].image}' 2>/dev/null || true)"

  step "Models — ensuring ServingRuntime"
  oc apply -n "$NS" -f "$HERE/models/serving-runtime.yaml" >/dev/null
  if [ -n "$vllm_img" ]; then
    if oc patch servingruntime vllm-cuda -n "$NS" --type=json \
         -p "[{\"op\":\"replace\",\"path\":\"/spec/containers/0/image\",\"value\":\"$vllm_img\"}]" >/dev/null 2>&1; then
      ok "vLLM runtime image set from cluster template"
    else
      skip "could not patch runtime image — using serving-runtime.yaml default"
    fi
  else
    skip "vllm-cuda-runtime-template not found — using serving-runtime.yaml default"
  fi

  # Build a tolerations patch that covers whatever taints the GPU nodes carry.
  if [ -z "$GPU_TAINT_KEYS" ]; then detect_gpu_taints; fi
  local tols="" k
  if [ -n "$GPU_TAINT_KEYS" ]; then
    for k in $GPU_TAINT_KEYS; do tols="$tols{\"key\":\"$k\",\"operator\":\"Exists\"},"; done
    tols="[${tols%,}]"
  fi

  # (Re)deploy only the models that need it.
  for m in "${todo[@]}"; do
    local f
    case "$m" in whisper-large-v3) f=whisper-stt.yaml ;; *) f=ministral-llm.yaml ;; esac
    step "Model $m — (re)deploying"
    oc delete -n "$NS" -f "$HERE/models/$f" --ignore-not-found >/dev/null 2>&1 || true
    oc apply  -n "$NS" -f "$HERE/models/$f" >/dev/null
    if [ -n "$tols" ]; then
      oc patch isvc "$m" -n "$NS" --type=merge \
        -p "{\"spec\":{\"predictor\":{\"tolerations\":$tols}}}" >/dev/null 2>&1 || true
    fi
  done
  if [ -n "$GPU_TAINT_KEYS" ]; then ok "Tolerations set for GPU node taint(s): $GPU_TAINT_KEYS"; fi

  step "Models — waiting for Ready (status every 5 min; auto-diagnoses crashes)"
  start_monitor
  local rc=0; wait_models || rc=1
  stop_monitor
  if [ "$rc" -eq 0 ]; then ok "Whisper STT + Ministral LLM Ready"
  else bad "Models did not reach Ready — see the diagnosis above."; fi
}
uninstall_models() {
  step "Removing models (Whisper + Ministral + ServingRuntime)"
  oc delete -n "$NS" -f "$HERE/models/whisper-stt.yaml" \
                     -f "$HERE/models/ministral-llm.yaml" \
                     -f "$HERE/models/serving-runtime.yaml" --ignore-not-found
  ok "Models removed"
}

# ---------- app (Supertonic TTS + web UI) ----------
# Skip a rebuild when the deployment is already running, unless --force.
deployment_healthy() { [ "$(oc get deploy "$1" -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)" -ge 1 ] 2>/dev/null; }

deploy_supertonic() {
  if [ "$FORCE" != "1" ] && deployment_healthy supertonic; then
    ok "Supertonic already running — keeping it (use --force to rebuild)"; return 0
  fi
  step "Supertonic (TTS) — removing any existing install first (idempotent)"
  oc delete -n "$NS" -f "$HERE/supertonic.yaml" --ignore-not-found >/dev/null 2>&1 || true
  step "Supertonic (TTS) — build image on-cluster + deploy"
  oc apply -n "$NS" -f "$HERE/supertonic.yaml" >/dev/null
  oc start-build supertonic --from-dir="$ROOT/supertonic" --follow -n "$NS"
  oc rollout status deploy/supertonic -n "$NS" --timeout=300s
  ok "Supertonic deployed"
}
deploy_webui() {
  if [ "$FORCE" != "1" ] && deployment_healthy smart-voice-assistant; then
    ok "Web UI already running — keeping it (use --force to rebuild new code)"; return 0
  fi
  step "Web UI — removing any existing install first (idempotent)"
  oc delete -n "$NS" -f "$HERE/webui.yaml" --ignore-not-found >/dev/null 2>&1 || true
  step "Web UI — build image on-cluster + deploy"
  oc apply -n "$NS" -f "$HERE/webui.yaml" >/dev/null
  oc start-build smart-voice-assistant --from-dir="$ROOT" --follow -n "$NS"
  oc rollout status deploy/smart-voice-assistant -n "$NS" --timeout=300s
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
' 2>/dev/null || true)"

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
      | python3 -c 'import sys,json;print(json.load(sys.stdin).get("choices",[{}])[0].get("message",{}).get("content","").strip())' 2>/dev/null || true)"
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
      | python3 -c 'import sys,json;print(json.load(sys.stdin).get("text","").strip())' 2>/dev/null || true)"
    if [ -n "$text" ]; then printf "%s✓%s  \"%s\"\n" "$GRN" "$RST" "$text"; pass=$((pass+1))
    else printf "%s✗%s  no transcript\n" "$RED" "$RST"; failed=$((failed+1)); fi
  fi

  rm -f "$wav"
  printf "\n%s%d passed%s, %s%d skipped%s, %s%d failed%s\n" \
    "$GRN" "$pass" "$RST" "$YLW" "$skipped" "$RST" "$RED" "$failed" "$RST"
  [ "$failed" -eq 0 ]
}

done_msg() { printf "\n%s✅ %s%s\n   %s\n" "$BOLD$GRN" "$1" "$RST" "$(route_url)"; }

# Stop the 3-minute status cron once the install is complete.
remove_status_cron() {
  command -v crontab >/dev/null 2>&1 || return 0
  if crontab -l 2>/dev/null | grep -q 'smart-voice-assistant/deploy'; then
    crontab -l 2>/dev/null | grep -v 'smart-voice-assistant/deploy' | grep -v 'smart-voice-assistant status monitor' | crontab - 2>/dev/null \
      && ok "Stopped the status cron (install complete)"
  fi
}

# Final SW + HW summary of what got deployed.
summary() {
  local url; url="$(route_url)"
  banner "Summary — software"
  printf "   Namespace   : %s\n" "$NS"
  printf "   App URL     : %s\n" "$url"
  local m uri ready role
  for m in whisper-large-v3 ministral-3-3b-instruct; do
    oc get isvc "$m" -n "$NS" >/dev/null 2>&1 || continue
    uri="$(oc get isvc "$m" -n "$NS" -o jsonpath='{.spec.predictor.model.storageUri}' 2>/dev/null || true)"
    ready="$(oc get isvc "$m" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    role=STT; [ "$m" = ministral-3-3b-instruct ] && role=LLM
    printf "   %-3s (%-24s ready=%-5s): %s\n" "$role" "$m" "${ready:-?}" "$uri"
  done
  local rimg; rimg="$(oc get servingruntime vllm-cuda -n "$NS" -o jsonpath='{.spec.containers[0].image}' 2>/dev/null || true)"
  [ -n "$rimg" ] && printf "   vLLM runtime: %s\n" "$rimg"
  oc get deploy supertonic -n "$NS" >/dev/null 2>&1 && printf "   TTS         : Supertonic 3 (%s)\n" "$(oc get deploy supertonic -n "$NS" -o jsonpath='{.status.readyReplicas}/{.spec.replicas} ready' 2>/dev/null || true)"
  oc get deploy smart-voice-assistant -n "$NS" >/dev/null 2>&1 && printf "   Web UI      : %s\n" "$(oc get deploy smart-voice-assistant -n "$NS" -o jsonpath='{.status.readyReplicas}/{.spec.replicas} ready' 2>/dev/null || true)"

  banner "Summary — hardware"
  oc get nodes -o json 2>/dev/null | python3 -c '
import sys,json
d=json.load(sys.stdin)
rows=[]
for n in d.get("items",[]):
    a=n.get("status",{}).get("allocatable",{})
    g=a.get("nvidia.com/gpu")
    if not g: continue
    L=n.get("metadata",{}).get("labels",{})
    prod=L.get("nvidia.com/gpu.product","GPU")
    drv=L.get("nvidia.com/cuda.driver.major","")+"."+L.get("nvidia.com/cuda.driver.minor","")
    rows.append((n["metadata"]["name"],prod,g,drv))
if not rows:
    print("   (no GPU nodes)")
for name,prod,g,drv in rows:
    print("   %-46s %s x%s  driver %s" % (name,prod,g,drv))
' 2>/dev/null
  for m in whisper-large-v3 ministral-3-3b-instruct; do
    oc get isvc "$m" -n "$NS" >/dev/null 2>&1 || continue
    local node; node="$(oc get pods -n "$NS" -l serving.kserve.io/inferenceservice="$m" -o jsonpath='{.items[-1:].spec.nodeName}' 2>/dev/null || true)"
    printf "   %-24s → %s\n" "$m" "${node:-<pending>}"
  done
}

# Wrap up: stop the cron on success, print the summary + a verdict.
finalize() {  # $1 = 1 if all component tests passed
  if [ "${1:-0}" = "1" ]; then remove_status_cron
  else skip "Some checks failed — leaving the status cron running so you can watch."; fi
  summary
  if [ "${1:-0}" = "1" ]; then
    printf "\n%s✅ Everything is working fine — install complete.%s\n   %s\n" "$BOLD$GRN" "$RST" "$(route_url)"
  else
    printf "\n%s⚠️  Install finished with issues — see the failures above.%s\n" "$BOLD$YLW" "$RST"
  fi
}
