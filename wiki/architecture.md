# Architecture

_Last updated: 2026-08-02_

## Components

| Component | Role | Runtime | Endpoint |
|-----------|------|---------|----------|
| Whisper large-v3 | STT | KServe/vLLM, **GPU** | `/v1/audio/transcriptions` |
| Ministral-3 3B Instruct | LLM | KServe/vLLM, **GPU** | `/v1/chat/completions` |
| Supertonic-3 | TTS | ONNX, **CPU-only** | `/v1/tts` (native) |
| Web UI | Browser app + **proxy** | Python (UBI9) | `/api/stt`, `/api/llm`, `/api/tts`, `/api/health`, `/api/config` |

## Request flow

Browser → **edge-TLS Route** → Web UI pod. The web UI is a **server-side proxy**:
the browser calls `/api/{stt,llm,tts}` and the pod forwards to the backend service
URLs. This avoids browser CORS and keeps any tokens server-side.

Endpoints are injected via the `smart-voice-assistant-config` **ConfigMap**
(`SVA_STT_ENDPOINT` / `SVA_LLM_ENDPOINT` / `SVA_TTS_ENDPOINT` + `_MODEL` / `_TOKEN`).
Precedence: **config.yaml (Settings) > env/ConfigMap > defaults**.

## Two app modes

- **Agentic AI mode** — STT → LLM → TTS (assistant answers).
- **Human mode** — bidirectional voice **translator**: each side's speech is
  translated into the other's language, no LLM answer.

## Images

- `quay.io/hasan_badawy_ai/smart-voice-assistant:v1.0.0` (web UI) — built from `Dockerfile`
- `quay.io/hasan_badawy_ai/supertonic:v1.0.0` (TTS) — built from `supertonic/Dockerfile`,
  **weights baked in** (~386 MB; on-disk ~1.71 GB, ~869 MB compressed pull)
- Models: public Red Hat AI ModelCar catalog
  (`oci://quay.io/redhat-ai-services/modelcar-catalog:{whisper-large-v3, ministral-3-3b-instruct-2512}`)
- All linux/amd64 (OCP nodes are x86_64).

## GPU

Models request `nvidia.com/gpu: "1"` each (2 total) — they don't provision
hardware. The install preflight reads GPU-node **taints** and auto-adds matching
tolerations, checks for ≥2 **free** GPUs, and uses `deploymentStrategy: Recreate`
(no replicas). Supertonic + web UI are CPU-only.
