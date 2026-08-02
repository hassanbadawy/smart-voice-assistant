# Supertonic 3 TTS server

Container build context for the Text-to-Speech backend used by Smart Voice
Assistant. [Supertonic 3](https://huggingface.co/Supertone/supertonic-3) is a
lightning-fast, on-device, **CPU-only** ONNX TTS covering **31 languages**.

Model weights (~26 files, Supertonic-3, ~386 MB) are **baked into the image at
build time** (`supertonic download` in the Dockerfile), so the pod needs **no
Hugging Face egress at runtime** — it works on disconnected / air-gapped
clusters. (Previously weights were pulled on first synth; on an air-gapped
cluster that hung and the OpenShift router returned a 504 on `/api/tts`.)

Native endpoint: `POST /v1/tts  {"text","voice","lang"}` → `audio/wav`.
Voices (preset): `M1 M3 M4 M5 F3 F4 F5`.  ⚠️ Urdu is not supported.

Built + deployed by `../deploy/full-install.sh` / `app-install.sh` (or the
`../deploy/supertonic.yaml` manifest directly).
