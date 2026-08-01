# Deploying to OpenShift

Four scripts drive everything (all take `-n NAMESPACE`, default = current project):

| Script | Does |
|--------|------|
| `full-install.sh`   | Models (STT+LLM) **+** Supertonic (TTS) **+** web UI, wires them, then **tests every component** |
| `app-install.sh`    | Supertonic **+** web UI only (**no models**), wires TTS, tests the app components |
| `full-uninstall.sh` | Removes the web UI, Supertonic, **and** the models |
| `app-uninstall.sh`  | Removes the web UI + Supertonic, **leaves the models** running |
| `status.sh`         | One-shot status snapshot (cron-able every 5 min) |

**Installs are idempotent** — each component is removed if it already exists,
then reinstalled fresh (so re-running is always clean).

```bash
oc login ...
oc new-project voice-assistant        # or: oc project <existing>

cd deploy
./full-install.sh -n voice-assistant       # models + app + tests + URL
```

Each install builds images on-cluster, waits for rollouts, wires the ConfigMap,
and finishes with a **component test through the public route**:

```
Testing components
  route: https://smart-voice-assistant-voice-assistant.apps.<domain>

[1/4] Web UI            ✓  /api/health 200
[2/4] TTS (Supertonic)  ✓  audio/wav, 165932 bytes
[3/4] LLM (Ministral)   ✓  "Hello!"
[4/4] STT (Whisper)     ✓  "component test"     ← round-trips the TTS clip back to text

4 passed, 0 skipped, 0 failed
```

`app-install.sh` skips the STT/LLM tests unless you've pointed `SVA_STT_ENDPOINT` /
`SVA_LLM_ENDPOINT` at your own models.

## Prerequisites

- **Models** (full install): RHOAI/KServe + the **NVIDIA GPU Operator** and a GPU
  per model. Details: [`models/README.md`](models/README.md).
- **App**: `registry.redhat.io` pull access (default on RHOAI) for the UBI base
  images; the build runs on-cluster (no local podman needed).

## GPU note

The model manifests **request** a GPU (`nvidia.com/gpu: "1"` each) — they do **not
provision** hardware. A GPU must already be schedulable (a GPU node + the NVIDIA
GPU Operator). `full-install.sh` runs a **preflight check** and warns (and, if
interactive, prompts) when no `nvidia.com/gpu` is allocatable, so pods don't
silently sit `Pending`. Quick check:

```bash
oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" gpu="}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}'
```

Actually adding GPU nodes is a cluster-admin task (a GPU MachineSet, or Cluster
Autoscaler on a GPU MachineSet) — outside these manifests.

## Monitoring the install

Model weight-pull can take several minutes. During the wait the installer prints
a **status snapshot immediately and then every 5 minutes** (model readiness, pod
phase, and the reason if a pod is stuck — e.g. `ImagePullBackOff` or
`Unschedulable`).

Check status anytime, or on a real 5-minute cron:

```bash
./status.sh -n voice-assistant
# crontab -e →
*/5 * * * * /path/to/deploy/status.sh -n voice-assistant >> /tmp/sva-status.log 2>&1
```

## What gets deployed

| Layer | Objects | Source |
|-------|---------|--------|
| Models | `ServingRuntime` + 2× `InferenceService` (KServe/vLLM) | public Red Hat AI ModelCar catalog (`oci://`, no secret) |
| TTS | Deployment + Service (Supertonic 3, ONNX/CPU) | built from `../supertonic/` |
| Web UI | ImageStream + BuildConfig + ConfigMap + Deployment + Service + edge Route | built from `..` |

The Route is **edge-TLS** (HTTPS) so the browser mic (`getUserMedia`) works.
Manifests are restricted-SCC compliant (non-root, drop all caps, seccomp, no
hard-coded uid).

## Configuration

The web-UI image is portable — endpoints come from `SVA_*` env (the ConfigMap in
`webui.yaml`, wired by the install scripts). Precedence: **config.yaml (Settings)
> env vars > defaults**.

| Env var | Purpose |
|---------|---------|
| `SVA_STT_ENDPOINT` / `SVA_STT_MODEL` / `SVA_STT_TOKEN` | Whisper `/v1` base |
| `SVA_LLM_ENDPOINT` / `SVA_LLM_MODEL` / `SVA_LLM_TOKEN` | LLM `/v1` base |
| `SVA_TTS_ENDPOINT` / `SVA_TTS_MODEL` / `SVA_TTS_TOKEN` | Supertonic endpoint |
| `SVA_TTS_API` | `native` (`/v1/tts`) or `openai` (`/v1/audio/speech`) |
| `SVA_TTS_FORMAT` | `wav` \| `flac` \| `ogg` |
| `SVA_APP_TITLE` | header title |

Re-point without a rebuild:

```bash
oc set data configmap/smart-voice-assistant-config SVA_LLM_ENDPOINT=http://my-llm/v1 -n $NS
oc rollout restart deploy/smart-voice-assistant -n $NS
```

## Manual / granular

Everything the scripts do is plain `oc apply` / `oc delete` on the manifests, so
you can run any single piece by hand — see [`models/README.md`](models/README.md)
for the model manifests, or apply `supertonic.yaml` / `webui.yaml` directly.

## Notes

- `config.yaml` (Settings edits incl. logo) is written to the pod and is
  **ephemeral** — prefer the env/ConfigMap wiring, or mount a PVC for persistence.
- Supertonic pulls weights from Hugging Face on first synth — the pod needs
  egress to `huggingface.co`, or pre-mirror for air-gap.
