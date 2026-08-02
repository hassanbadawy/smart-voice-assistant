# Deploying to OpenShift

Four scripts drive everything (all take `-n NAMESPACE`, default = current project):

| Script | Does |
|--------|------|
| `full-install.sh`   | Models (STT+LLM) **+** Supertonic (TTS) **+** web UI, wires them, then **tests every component** |
| `app-install.sh`    | Supertonic **+** web UI only (**no models**), wires TTS, tests the app components |
| `full-uninstall.sh` | Removes the web UI, Supertonic, **and** the models |
| `app-uninstall.sh`  | Removes the web UI + Supertonic, **leaves the models** running |
| `status.sh`         | One-shot status snapshot (cron-able every 5 min) |
| `gpu-status.sh`     | Cluster GPU inventory: specs, EMPTY/ENGAGED state, live utilization |

**Installs skip healthy components** — any model or service that's already
`Ready` in the namespace is kept as-is (a model re-pull is slow and yields the
same result). Unhealthy/missing pieces are (re)installed. Use `--force` to
rebuild/re-pull everything (e.g. after changing the web-UI code).

**Components deploy in parallel by default** — Supertonic and the web UI build
while the models pull (wall-clock ≈ the slowest one, not the sum). A combined
status prints every 30s; on join, each component's result is reported. Use
`--sequential` for one-at-a-time with inline build logs.

Flags (all scripts): `-n NAMESPACE` · `-f/--force` (reinstall even if healthy) ·
`--registry REPO` (prebuilt images, no on-cluster build) · `--sequential`
(deploy one-by-one) · `-y/--yes` (skip prompts, for CI) · `--timeout SECONDS`
(model-ready wait, default 900).

## Clusters without an internal image registry (bare-metal / disconnected)

By default the scripts **build the web-UI and Supertonic images on-cluster** via
`BuildConfig` → internal registry. If your cluster has no internal registry (you'll
see `InvalidOutputReference: Output image could not be resolved`), build the images
once and push them to a registry the cluster can pull from (e.g. quay.io):

```bash
podman login quay.io
./build-push.sh -r quay.io/<you>                         # builds + pushes both images
./full-install.sh -n voice-assistant --registry quay.io/<you>
```

With `--registry`, the scripts skip the on-cluster build, pin the Deployment to the
external image, and — if the repo is private — create a namespace pull secret from
your local `podman`/`docker` login automatically. (Set `SVA_WEBUI_IMAGE` /
`SVA_TTS_IMAGE` for fully custom refs.) The preflight also reports whether the
internal registry is `Managed`, so the on-cluster path fails fast with this hint.

On a full install the script also:
- **Preflights** the cluster: RHOAI/KServe, `registry.redhat.io` pull secret, the
  vLLM runtime template (correct GPU image), and **GPU schedulability** — it reads
  the GPU nodes' taints and **auto-adds matching tolerations**, so it works on
  clusters that dedicate GPU nodes with any taint key.
- **Auto-diagnoses** a stuck model — on crash-loop or timeout it prints the
  scheduling reason or the container's last error (no manual log-digging).
- On success, **stops the status cron** and prints a **software + hardware
  summary** (models, images, TTS/UI, GPU type/driver, per-model node placement).

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

The model manifests **request** a GPU (`nvidia.com/gpu: "1"` each, 2 total) — they
do **not provision** hardware. A GPU must already be schedulable (a GPU node + the
NVIDIA GPU Operator). The preflight:

- checks there are **≥ 2 free** GPUs (allocatable minus what other namespaces
  already use — a namespace's own GPUs don't count against it, so re-runs pass);
- reads the GPU nodes' **taints** (e.g. `nvidia.com/gpu:NoSchedule`) and
  **auto-adds matching tolerations** to the model pods, so it works on clusters
  that dedicate GPU nodes with any taint key.

Inspect GPUs anytime — specs, EMPTY/ENGAGED state, and live utilization:

```bash
./gpu-status.sh            # whole cluster
./gpu-status.sh -n <ns>    # highlight GPUs engaged by a namespace
```

Adding GPU nodes is a cluster-admin task (a GPU MachineSet, or Cluster Autoscaler
on a GPU MachineSet) — outside these manifests.

## Monitoring the install

Model weight-pull can take several minutes. During the wait the installer prints
a **status snapshot immediately and then every 5 minutes** (model readiness, pod
phase, and the reason if a pod is stuck — e.g. `ImagePullBackOff` or
`Unschedulable`).

Check status anytime, or on a real 5-minute cron:

```bash
./status.sh -n voice-assistant
# crontab -e →  (cron has a minimal env — set PATH + KUBECONFIG)
*/3 * * * * cd /path/to/deploy && PATH=/opt/homebrew/bin:/usr/bin:/bin KUBECONFIG=$HOME/.kube/config ./status.sh -n voice-assistant >> /tmp/sva-status.log 2>&1
```

Remove it with `crontab -e` (delete the line) or `crontab -r` (clears all).

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

## Troubleshooting

The installer **auto-diagnoses** a stuck model (prints the scheduling reason or
the container's last error and exits early), so you rarely need to dig. Common
causes it surfaces:

| Symptom | Cause / fix |
|---------|-------------|
| Model pod `Pending` / `Unschedulable` | No free GPU, or a GPU-node **taint** not tolerated. `./gpu-status.sh` shows free GPUs; the preflight auto-tolerates detected taints. |
| `CUDA error 803` / unknown architecture | Wrong vLLM image for the cluster's driver. The install **auto-detects** the right image from `vllm-cuda-runtime-template`; ensure RHOAI is installed. |
| Model `CrashLoopBackOff` | Auto-diagnosed with the last error line. Often an image/driver or model-format mismatch. |
| STT/LLM tests "skipped" | Endpoints weren't wired — full-install wires them; `app-install` leaves them for you (`SVA_STT_ENDPOINT` / `SVA_LLM_ENDPOINT`). |
| A run dies mid-way (e.g. API `TLS handshake timeout`) | Transient — just **re-run**; skip-if-healthy makes it resume in seconds. |
| Two full stacks won't fit | Each stack needs 2 GPUs. `./gpu-status.sh` shows what's engaged; `./full-uninstall.sh -n <other-ns>` frees them. |
| `/api/tts` returns **504** | See below — either the router timeout, onnxruntime thread explosion, or (old images) a runtime HF download. All three are fixed in the current manifests. |
| Prebuilt image → `ImagePullBackOff` `unauthorized` | The quay repo is **private** and the cluster has no pull secret. Make the repo public, or `podman login` on the machine running the script (it copies the credential), or create a pull secret. |

## Gotchas we've already fixed (and how to avoid them)

These bit us on a real disconnected GPU cluster. The current manifests/images
prevent them — this is the reasoning so they don't regress:

1. **TTS 504 — runtime Hugging Face download (air-gap).** Supertonic used to pull
   its weights from HF on the *first* synth; on an air-gapped cluster that hangs
   → router 504. **Fixed:** weights are now **baked into the image** at build time
   (`supertonic/Dockerfile`), so there's zero HF egress at runtime.
2. **TTS 504 — onnxruntime thread explosion.** Left on auto, onnxruntime spawns
   one thread per **host** core (dozens on a GPU node) while the pod is CPU-capped
   → thrashing turns a 3s synth into 40-70s → router 504. **Fixed:** `supertonic.yaml`
   pins `SUPERTONIC_INTRA_OP_THREADS` **equal to `limits.cpu`**. If you change the
   CPU limit, change the thread count to match.
3. **TTS 504 — router timeout.** CPU synth can exceed the router's 30s default.
   **Fixed:** the Route carries `haproxy.router.openshift.io/timeout: 120s`.
4. **New image not picked up on re-deploy.** A pushed `:latest` won't roll out if
   the node caches the old layer. **Fixed:** both app Deployments set
   `imagePullPolicy: Always`. Note skip-if-healthy also keeps a *running* pod —
   use `--force` (or `oc rollout restart`) to pull a freshly pushed image.
5. **Private quay repos → `ImagePullBackOff`.** Prebuilt images must be pullable:
   make the quay repos **public**, or ensure a pull secret exists (the installer
   copies your local `podman login` credential when it can).
6. **Component-test false negatives during rollout.** Both app Deployments use
   `strategy: Recreate` so an old pod never sits behind the Route next to the new
   one; the test also waits for a *populated* config before probing.

## Notes

- `config.yaml` (Settings edits incl. logo) is written to the pod and is
  **ephemeral** — prefer the env/ConfigMap wiring, or mount a PVC for persistence.
- Supertonic weights are **baked into the image** (no runtime Hugging Face
  egress) — see [`../supertonic/README.md`](../supertonic/README.md).
