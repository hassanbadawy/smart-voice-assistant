# Supertonic 3 TTS server

Container build context for the Text-to-Speech backend used by Smart Voice
Assistant. [Supertonic 3](https://huggingface.co/Supertone/supertonic-3) is a
lightning-fast, on-device, **CPU-only** ONNX TTS covering **31 languages**.

Model weights (~26 files) are fetched from Hugging Face on first synth, so the
pod needs egress to `huggingface.co` (or pre-mirror the weights for air-gap).

Native endpoint: `POST /v1/tts  {"text","voice","lang"}` → `audio/wav`.
Voices (preset): `M1 M3 M4 M5 F3 F4 F5`.  ⚠️ Urdu is not supported.

Built + deployed by `../deploy/deploy.sh` (or the manifests in `../deploy/`).
