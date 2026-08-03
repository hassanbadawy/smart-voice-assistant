# Troubleshooting — root-caused issues & permanent fixes

Every entry here was hit on a **real disconnected GPU cluster** (Zain
`zainksa-testai`, registry-less, air-gapped) and is now fixed in the
images/manifests. Kept as a record so the fixes don't regress and future
debugging starts here.

_Last updated: 2026-08-02_

---

## `/api/tts` returns 504 — THREE distinct root causes

The single symptom "TTS 504" had three unrelated causes. All are fixed now; if
504 ever returns, walk them in this order.

### 1. Runtime Hugging Face download (air-gap)
- **Symptom:** first `/api/tts` hangs → router 504. STT/LLM fine.
- **Cause:** Supertonic fetched its ~386 MB weights from `huggingface.co` on the
  **first synth**. On an air-gapped cluster that never completes.
- **Fix (permanent):** weights are **baked into the image** at build time —
  `supertonic/Dockerfile` runs `supertonic download` into `SUPERTONIC_CACHE_DIR`
  (`/opt/app-root/supertonic-models`), which both `download` and `serve` resolve.
  Runtime needs **zero** HF egress. Verified offline with `HF_HUB_OFFLINE=1`.
- **Verify:** `oc exec deploy/supertonic -- du -sh /opt/app-root/supertonic-models`
  → ~386M means the baked (new) image.

### 2. onnxruntime thread explosion under a CPU cgroup  ← the worst one
- **Symptom:** synth takes **44–73s** (cold 73s, warm 44s) even with weights
  baked; router 504. Supertonic logs show only `/docs` probes (uvicorn logs a
  POST only *after* it finishes, so a slow synth looks like "no request").
- **Cause:** onnxruntime left on auto spawns **one thread per HOST core** (dozens
  on a GPU node) while the pod is capped at `limits.cpu: 2` → thread thrashing.
  Same synth is ~3s on a laptop with sane thread counts.
- **Fix (permanent):** `supertonic.yaml` sets
  `SUPERTONIC_INTRA_OP_THREADS` / `SUPERTONIC_INTER_OP_THREADS` / `OMP_NUM_THREADS`
  and raises `limits.cpu` to 8. **The thread count MUST equal `limits.cpu`.**
  These env vars are Supertonic's own knobs (`config.py` → `_parse_env_int`).
- **GOLDEN RULE:** change the CPU limit → change the thread env to match.

### 3. Router timeout on CPU synth
- **Symptom:** synth completes in the pod but the browser still 504s.
- **Cause:** OpenShift router default HAProxy timeout is **30s**; a CPU synth can
  exceed it.
- **Fix (permanent):** Route carries `haproxy.router.openshift.io/timeout: 120s`
  (in `webui.yaml`).

**Isolate which one:** run a synth *inside* the pod (bypasses router + web UI) —
`oc exec -i deploy/supertonic -- python3 -` POSTing to `http://127.0.0.1:7788/v1/tts`.
Time it: fast in-pod but 504 through the route = #3; slow in-pod = #2; hangs
forever / connection issues = #1. (Note `oc exec` needs **`-i`** to pass a heredoc.)

---

## Prebuilt image → `ImagePullBackOff: unauthorized`
- **Cause:** the quay repo is **private** and the cluster has no pull secret. The
  installer's auto-secret only works if the **machine running the script** is
  `podman login`'d to quay — a bastion that never logged in has no credential to
  copy, so the pod falls back to anonymous → 401.
- **Fixes:** (a) make the quay repos **public** (simplest for non-secret app
  images); or (b) `podman login quay.io` on the bastion then re-run; or (c)
  `oc create secret docker-registry` (a quay robot account) + `oc secrets link
  default <secret> --for=pull`.

## New `:latest` push not picked up on re-deploy
- **Cause 1:** skip-if-healthy keeps a *running* pod as-is (by design, to avoid
  slow re-pulls). A plain re-run won't replace it → use `--force` or
  `oc rollout restart`.
- **Cause 2:** even on restart, a node can reuse a cached `:latest` layer.
- **Fix (permanent):** both app Deployments set `imagePullPolicy: Always`.
- **Verify a pod is on the new image:** check for the baked weights (see #1) or
  compare `oc get pod ... -o jsonpath='{...imageID}'` to the pushed digest.

## Component-test false negative during rollout
- **Symptom:** post-install test reports TTS/LLM failures on a healthy stack.
- **Cause:** with RollingUpdate, the old pod (empty/stale endpoints) briefly sat
  behind the Route next to the new one; `oc rollout status` returns before the
  router drops the old endpoint, so the test load-balanced onto it.
- **Fix (permanent):** both app Deployments use `strategy: Recreate` (one pod
  ever); the test also waits for a **populated** `/api/config` before probing.

---

## Cross-platform build notes (macOS → OCP)
- OCP nodes are **x86_64**; a Mac (arm64) must build `--platform linux/amd64`
  (`build-push.sh` defaults to this). An arm64 image silently `CrashLoopBackOff`s.
- Pin `supertonic[serve]==1.3.1` in the Dockerfile — an unpinned `[serve]`
  install backtracked to `0.0.1` (no CLI) → `supertonic: command not found`.
- podman on macOS occasionally drops the machine connection mid-build
  (`unable to connect to Podman socket`) — `podman machine stop && start`.
- **Don't `podman run --platform linux/amd64 <tag>` right after building** — it can
  re-pull the remote (old) image and overwrite your fresh local tag. Verify by
  **image ID**, then `podman tag` + `podman push`.
