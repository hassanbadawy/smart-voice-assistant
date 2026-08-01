#!/bin/bash
# List cluster GPUs with EMPTY/ENGAGED state, full specs, and live utilization.
# Usage: ./gpu-status.sh [-n NAMESPACE]   (-n highlights GPUs engaged by NS)

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; RED='\033[0;31m'; DIM='\033[2m'; NC='\033[0m'
header() { echo -e "\n${YELLOW}=== $1 ===${NC}\n"; }

FILTER_NS=""
while [ $# -gt 0 ]; do
  case "$1" in
    -n|--namespace) FILTER_NS="$2"; shift 2 ;;
    -h|--help) grep -E '^# ' "$0" | sed 's/^# //'; exit 0 ;;
    *) shift ;;
  esac
done
oc whoami >/dev/null 2>&1 || { echo "Not logged in — run 'oc login ...' first"; exit 1; }

NODES_JSON="$(oc get nodes -o json 2>/dev/null)"
PODS_JSON="$(oc get pods -A -o json 2>/dev/null)"

# ------------------------------------------------------------------
header "GPU Nodes — specs & state"
# ------------------------------------------------------------------
printf "${BLUE}%-45s %-16s %-5s %-5s %-5s %-11s %-10s %-8s${NC}\n" \
  "NODE" "MODEL" "TOTAL" "USED" "FREE" "STATE" "VRAM(MiB)" "DRIVER"
printf "%-45s %-16s %-5s %-5s %-5s %-11s %-10s %-8s\n" \
  "----" "-----" "-----" "----" "----" "-----" "---------" "------"

printf '%s\0%s' "$NODES_JSON" "$PODS_JSON" | python3 -c "
import sys, json
raw = sys.stdin.buffer.read().split(b'\x00')
nodes = json.loads(raw[0] or b'{}'); pods = json.loads(raw[1] or b'{}')
G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; NC='\033[0m'
alloc = {}
for p in pods.get('items', []):
    if p.get('status', {}).get('phase') not in ('Running', 'Pending'): continue
    node = p.get('spec', {}).get('nodeName')
    if not node: continue
    g = 0
    for c in p['spec'].get('containers', []) + p['spec'].get('initContainers', []):
        r = c.get('resources', {})
        v = r.get('limits', {}).get('nvidia.com/gpu') or r.get('requests', {}).get('nvidia.com/gpu')
        if v: g += int(v)
    if g: alloc[node] = alloc.get(node, 0) + g
tot_all=tot_used=0
for n in nodes.get('items', []):
    cnt = n['status'].get('allocatable', {}).get('nvidia.com/gpu')
    if not cnt: continue
    cnt = int(cnt); name = n['metadata']['name']; L = n['metadata'].get('labels', {})
    model = L.get('nvidia.com/gpu.product', '?')
    vram = L.get('nvidia.com/gpu.memory', '?')
    drv = '.'.join(x for x in [L.get('nvidia.com/cuda.driver.major',''), L.get('nvidia.com/cuda.driver.minor',''), L.get('nvidia.com/cuda.driver.rev','')] if x) or '?'
    used = alloc.get(name, 0); free = cnt - used
    tot_all += cnt; tot_used += used
    if used >= cnt: st, col = 'FULL', R
    elif used > 0:  st, col = 'ENGAGED', Y
    else:           st, col = 'EMPTY', G
    print(f'{name:<45} {model:<16} {cnt:<5} {used:<5} {free:<5} {col}{st:<11}{NC} {vram:<10} {drv:<8}')
print()
print(f'{\"\":<45} {\"\":<16} {tot_all:<5} {tot_used:<5} {tot_all-tot_used:<5} {\"(cluster)\":<11}')
" 2>/dev/null || echo "No GPU nodes found."

# ------------------------------------------------------------------
header "GPU Utilization (live — nvidia-smi)"
# ------------------------------------------------------------------
GPU_NODES=$(echo "$NODES_JSON" | python3 -c "
import sys,json
for n in json.load(sys.stdin).get('items',[]):
    if n['status'].get('allocatable',{}).get('nvidia.com/gpu'): print(n['metadata']['name'])
" 2>/dev/null)

if [ -z "$GPU_NODES" ]; then
  echo "No GPU nodes."
else
  printf "${BLUE}%-30s %-3s %-14s %-15s %-6s %-6s %-7s %-4s${NC}\n" \
    "NODE" "IDX" "NAME" "MEM used/total" "UTIL" "TEMP" "POWER" "CC"
  printf "%-30s %-3s %-14s %-15s %-6s %-6s %-7s %-4s\n" \
    "----" "---" "----" "--------------" "----" "----" "-----" "--"
  for node in $GPU_NODES; do
    short="${node%%.*}"
    pods_on_node="$(oc get pods -A --field-selector "spec.nodeName=$node" \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null)"
    # the driver daemonset definitely has nvidia-smi; dcgm as fallback
    dp="$(echo "$pods_on_node" | grep 'nvidia-driver-daemonset' | head -1)"
    [ -z "$dp" ] && dp="$(echo "$pods_on_node" | grep -E 'nvidia-dcgm' | head -1)"
    if [ -z "$dp" ]; then
      printf "%-30s ${DIM}nvidia-smi unavailable (no driver pod)${NC}\n" "$short"
      continue
    fi
    smi="$(oc exec -n "${dp%% *}" "${dp#* }" -- nvidia-smi \
      --query-gpu=index,name,memory.used,memory.total,utilization.gpu,temperature.gpu,power.draw,compute_cap \
      --format=csv,noheader,nounits 2>/dev/null)"
    if [ -z "$smi" ]; then
      printf "%-30s ${DIM}nvidia-smi exec failed${NC}\n" "$short"
      continue
    fi
    echo "$smi" | while IFS=',' read -r idx name mused mtot util temp power cc; do
      printf "%-30s %-3s %-14s %6s/%-8s %4s%%  %4s°C %5sW  %s\n" \
        "$short" "$(echo "$idx"|xargs)" "$(echo "$name"|xargs)" \
        "$(echo "$mused"|xargs)" "$(echo "$mtot"|xargs)" "$(echo "$util"|xargs)" \
        "$(echo "$temp"|xargs)" "$(echo "$power"|xargs)" "$(echo "$cc"|xargs)"
      short=""   # only print node name on the first GPU row
    done
  done
fi

# ------------------------------------------------------------------
header "GPU Pod Assignments (engaged by)"
# ------------------------------------------------------------------
printf "${BLUE}%-50s %-22s %-5s %-40s${NC}\n" "POD" "NAMESPACE" "GPUs" "NODE"
printf "%-50s %-22s %-5s %-40s\n" "---" "---------" "----" "----"
echo "$PODS_JSON" | FILTER_NS="$FILTER_NS" python3 -c "
import json, sys, os
data = json.load(sys.stdin); flt = os.environ.get('FILTER_NS','')
C='\033[0;36m'; NC='\033[0m'; found = False
for pod in data.get('items', []):
    if pod.get('status', {}).get('phase') not in ('Running','Pending'): continue
    node = pod.get('spec', {}).get('nodeName', ''); ns = pod['metadata']['namespace']; name = pod['metadata']['name']
    g = 0
    for c in pod['spec'].get('containers', []) + pod['spec'].get('initContainers', []):
        r = c.get('resources', {})
        v = r.get('limits', {}).get('nvidia.com/gpu') or r.get('requests', {}).get('nvidia.com/gpu')
        if v: g += int(v)
    if g:
        found = True
        mark = f'  {C}<- {flt}{NC}' if flt and ns == flt else ''
        print(f'{name[:50]:<50} {ns:<22} {g:<5} {node}{mark}')
if not found: print('No pods using GPUs.')
" 2>/dev/null

echo ""
