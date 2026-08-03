# Deployment

_Last updated: 2026-08-02_

## Scripts (`deploy/`)

| Script | Does |
|--------|------|
| `full-install.sh` | Models + Supertonic + web UI, wires endpoints, tests every component |
| `app-install.sh` | Supertonic + web UI only (no models), wires TTS |
| `full-uninstall.sh` / `app-uninstall.sh` | Remove with/without models |
| `status.sh` / `gpu-status.sh` | Status snapshot / GPU inventory |
| `build-push.sh` | Build + push app images to a registry (`--platform linux/amd64` default) |

Flags: `-n NS` · `-f/--force` (reinstall even if healthy) · `--registry REPO`
(prebuilt images, no on-cluster build) · `--sequential` · `-y/--yes` ·
`--timeout SECONDS`.

## Two deploy modes

1. **On-cluster build** (default) — `BuildConfig` → internal registry. Requires a
   Managed internal registry.
2. **Prebuilt-image** (`--registry quay.io/hasan_badawy_ai`) — for
   **registry-less / disconnected** clusters. Skips builds, pins Deployments to the
   external image, and auto-creates a pull secret from local `podman` login if the
   repo is private. Build+push first with `build-push.sh -r <repo>`.

Preflight auto-detects which is possible (reports internal-registry
`managementState`).

## Parallel by default

`deploy_all()` backgrounds models + Supertonic + web UI so builds overlap the
model pull (wall-clock ≈ slowest component, not the sum). Prints combined status
every `STATUS_EVERY` (30s); always returns 0 so a single failure surfaces in the
component test, not an abort. `--sequential` opts out.

## Idempotence / skip-if-healthy

Any model or service already `Ready` in the namespace is **kept** (a re-pull is
slow and yields the same result). `--force` overrides. **Caveat:** a freshly
pushed image won't roll out over a *healthy* pod without `--force` (or
`oc rollout restart`) — see [troubleshooting.md](troubleshooting.md).

## Manifest invariants (don't regress — see troubleshooting.md)

- `supertonic.yaml`: `SUPERTONIC_INTRA_OP_THREADS` == `limits.cpu`;
  `imagePullPolicy: Always`; `strategy: Recreate`; weights baked in the image.
- `webui.yaml`: `imagePullPolicy: Always`; `strategy: Recreate`; Route
  `haproxy.router.openshift.io/timeout: 120s`.

## Behavioural rule

Do **not** deploy to a cluster or spin up test workloads unless explicitly asked —
validate logic locally (`bash -n`, mocked functions). (Recorded after a
self-initiated validation deploy was corrected.)
