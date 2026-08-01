#!/bin/bash
# List OpenShift cluster hardware: nodes, GPUs, and GPU pod assignments
# Usage: ./test-gpus.sh

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

header() { echo -e "\n${YELLOW}=== $1 ===${NC}\n"; }

# -----------------------------------------------
header "All Nodes"
# -----------------------------------------------
printf "${BLUE}%-45s %-12s %-6s %-10s %-6s %-8s${NC}\n" "NODE" "ROLE" "CPU" "MEMORY" "GPU" "STATUS"
printf "%-45s %-12s %-6s %-10s %-6s %-8s\n" "----" "----" "---" "------" "---" "------"

oc get nodes -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for n in data['items']:
    name = n['metadata']['name']
    labels = n['metadata'].get('labels', {})
    cap = n['status'].get('capacity', {})
    conds = {c['type']: c['status'] for c in n['status'].get('conditions', [])}

    roles = []
    if 'node-role.kubernetes.io/master' in labels or 'node-role.kubernetes.io/control-plane' in labels:
        roles.append('master')
    if 'node-role.kubernetes.io/worker' in labels:
        roles.append('worker')
    role = ','.join(roles) or 'worker'

    cpu = cap.get('cpu', '?')
    mem_ki = cap.get('memory', '0Ki').replace('Ki', '')
    try:
        mem_gi = f'{int(mem_ki) // 1048576}Gi'
    except:
        mem_gi = cap.get('memory', '?')

    gpu = cap.get('nvidia.com/gpu', '-')
    status = 'Ready' if conds.get('Ready') == 'True' else 'NotReady'

    print(f'{name:<45} {role:<12} {cpu:<6} {mem_gi:<10} {gpu:<6} {status}')
"

# -----------------------------------------------
header "GPU Nodes (detailed)"
# -----------------------------------------------
GPU_COUNT=$(oc get nodes -l nvidia.com/gpu.present=true --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$GPU_COUNT" -eq 0 ]; then
  echo "No GPU nodes found."
else
  printf "${BLUE}%-45s %-15s %-6s %-10s %-15s${NC}\n" "NODE" "GPU MODEL" "COUNT" "VRAM(MB)" "DRIVER"
  printf "%-45s %-15s %-6s %-10s %-15s\n" "----" "---------" "-----" "--------" "------"

  oc get nodes -l nvidia.com/gpu.present=true -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for n in data['items']:
    name = n['metadata']['name']
    labels = n['metadata'].get('labels', {})
    cap = n['status'].get('capacity', {})
    gpu_model = labels.get('nvidia.com/gpu.product', '?')
    gpu_count = cap.get('nvidia.com/gpu', '?')
    gpu_mem = labels.get('nvidia.com/gpu.memory', '?')
    driver = labels.get('nvidia.com/cuda.driver.major', '') + '.' + labels.get('nvidia.com/cuda.driver.minor', '')
    if driver == '.':
        driver = labels.get('nvidia.com/cuda.runtime.major', '-')
    print(f'{name:<45} {gpu_model:<15} {gpu_count:<6} {gpu_mem:<10} {driver}')
"
fi

# -----------------------------------------------
header "GPU Pod Assignments"
# -----------------------------------------------
printf "${BLUE}%-50s %-20s %-6s %-40s${NC}\n" "POD" "NAMESPACE" "GPUs" "NODE"
printf "%-50s %-20s %-6s %-40s\n" "---" "---------" "----" "----"

oc get pods -A -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
found = False
for pod in data['items']:
    phase = pod.get('status', {}).get('phase', '')
    if phase != 'Running':
        continue
    node = pod.get('spec', {}).get('nodeName', '')
    ns = pod['metadata']['namespace']
    name = pod['metadata']['name']
    for c in pod['spec'].get('containers', []):
        gpu = c.get('resources', {}).get('limits', {}).get('nvidia.com/gpu', '')
        if gpu:
            found = True
            print(f'{name[:50]:<50} {ns:<20} {gpu:<6} {node}')
if not found:
    print('No pods using GPUs found.')
"

# -----------------------------------------------
header "InferenceServices"
# -----------------------------------------------
oc get inferenceservice -A --no-headers 2>/dev/null | \
  awk '{printf "%-50s %-20s %-8s %s\n", $2, $1, $3, $4}' || echo "No InferenceServices found."

echo ""
