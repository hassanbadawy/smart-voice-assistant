# Smart Voice Assistant — Project Wiki

Empirical, cross-session knowledge for the smart-voice-assistant codebase.
Complements `README.md` (usage) and `deploy/README.md` (deploy reference) — this
wiki records *why* things are the way they are and what we learned the hard way.

## Pages

| Page | What it covers |
|------|----------------|
| [architecture.md](architecture.md) | Components, request flow, images, endpoints |
| [deployment.md](deployment.md) | OpenShift deploy model (build vs prebuilt), install scripts, parallel deploy |
| [troubleshooting.md](troubleshooting.md) | Root-caused production issues + permanent fixes (the 504 saga, image-pull, air-gap) |

## Quick facts

- **Stack:** Whisper large-v3 (STT) + Ministral-3 3B (LLM) on KServe/vLLM (GPU) +
  Supertonic-3 (TTS, ONNX/CPU) + a Python web-UI proxy (`/api/stt|llm|tts`).
- **Images:** app images at `quay.io/hasan_badawy_ai/{smart-voice-assistant,supertonic}:latest`
  (linux/amd64). Models come from the public Red Hat AI ModelCar catalog.
- **Two deploy modes:** on-cluster build (internal registry) or `--registry`
  prebuilt-image mode (disconnected / registry-less clusters).
- **Golden rule:** Supertonic `SUPERTONIC_INTRA_OP_THREADS` must equal its
  `limits.cpu` — see [troubleshooting.md](troubleshooting.md).

_Last updated: 2026-08-02_
