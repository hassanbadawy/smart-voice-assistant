# Deploying to OpenShift

Two components:

| App | What | Image |
|-----|------|-------|
| `smart-voice-assistant` | Web UI + config/proxy server (`/api/tts\|stt\|llm`) | UBI9 Python, built from `../Dockerfile` |
| `supertonic` | Supertonic 3 TTS backend (ONNX, CPU-only) | built from `../supertonic/Dockerfile` |

STT + LLM are **not** deployed here — point the app at your existing
OpenAI-compatible Whisper + LLM via the ConfigMap in `webui.yaml`.

## Quick start

```bash
oc login ...
oc new-project voice-assistant        # or: oc project <existing>

cd deploy
./deploy.sh -n voice-assistant        # builds both images on-cluster, deploys, prints the URL
```

Skip the TTS backend (using an external Supertonic) with `--no-supertonic`.

## Manual (declarative) path

```bash
NS=voice-assistant

# TTS backend (optional)
oc apply -n $NS -f supertonic.yaml
oc start-build supertonic --from-dir=../supertonic --follow -n $NS

# Web UI
oc apply -n $NS -f webui.yaml
oc start-build smart-voice-assistant --from-dir=.. --follow -n $NS

oc get route smart-voice-assistant -n $NS -o jsonpath='https://{.spec.host}{"\n"}'
```

The `Deployment`s use ImageStream triggers, so each `oc start-build` auto-rolls
out the new image.

## Configuration

The image is portable; endpoints are injected via env (see the ConfigMap in
`webui.yaml`). Precedence at runtime is **config.yaml (Settings) > env vars >
built-in defaults**.

| Env var | Purpose |
|---------|---------|
| `SVA_STT_ENDPOINT` / `SVA_STT_MODEL` / `SVA_STT_TOKEN` | Whisper `/v1` base |
| `SVA_LLM_ENDPOINT` / `SVA_LLM_MODEL` / `SVA_LLM_TOKEN` | LLM `/v1` base |
| `SVA_TTS_ENDPOINT` / `SVA_TTS_MODEL` / `SVA_TTS_TOKEN` | Supertonic endpoint |
| `SVA_TTS_API` | `native` (`/v1/tts`) or `openai` (`/v1/audio/speech`) |
| `SVA_TTS_FORMAT` | `wav` \| `flac` \| `ogg` |
| `SVA_APP_TITLE` | header title |

Change endpoints without a rebuild:

```bash
oc set data configmap/smart-voice-assistant-config SVA_LLM_ENDPOINT=http://my-llm/v1 -n $NS
oc rollout restart deploy/smart-voice-assistant -n $NS
```

## Notes

- The **Route is edge-TLS** (HTTPS) so the browser mic (`getUserMedia`) works.
- Manifests are **restricted-SCC compliant**: `runAsNonRoot`, no privilege
  escalation, all capabilities dropped, `RuntimeDefault` seccomp, no hard-coded
  uid (OCP assigns one from the namespace range).
- `config.yaml` (Settings edits, incl. logo) is written to the pod filesystem
  and is **ephemeral** — it resets on restart. For persistence, mount a PVC at
  the app dir; for a fixed deployment, prefer the env/ConfigMap wiring above.
- Supertonic pulls its weights from Hugging Face on first synth — the pod needs
  egress to `huggingface.co`, or pre-mirror the weights for air-gapped clusters.
