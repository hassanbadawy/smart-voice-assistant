# Installing the STT + LLM models (CLI)

Deploys the two backing models as **KServe InferenceServices** served by vLLM
(Red Hat AI Inference Server). Weights come from the **public Red Hat AI ModelCar
catalog** (`quay.io/redhat-ai-services/modelcar-catalog`) as `oci://` images — no
S3 bucket or pull secret required.

| Model | Role | ModelCar tag | OpenAI endpoint |
|-------|------|--------------|-----------------|
| `whisper-large-v3` | STT | `whisper-large-v3` | `/v1/audio/transcriptions` |
| `ministral-3-3b-instruct` | LLM | `ministral-3-3b-instruct-2512` | `/v1/chat/completions` |

The served model id equals the InferenceService name (the ServingRuntime sets
`--served-model-name={{.Name}}`).

## Prerequisites

- OpenShift with **RHOAI / KServe** (the `InferenceService` + `ServingRuntime` CRDs).
- **NVIDIA GPU Operator** and at least one schedulable GPU. Each model requests
  **1 GPU** (2 total by default); shrink by lowering replicas or sharing a node.
- `registry.redhat.io` pull access for the vLLM image (default on RHOAI clusters).

## Install

Usually installed as part of [`../full-install.sh`](../README.md). To install the
models on their own:

```bash
oc login ...
oc project voice-assistant
NS=voice-assistant

oc apply -n $NS -f serving-runtime.yaml -f whisper-stt.yaml -f ministral-llm.yaml
oc wait -n $NS --for=condition=Ready inferenceservice/whisper-large-v3 --timeout=900s
oc wait -n $NS --for=condition=Ready inferenceservice/ministral-3-3b-instruct --timeout=900s
```

## Uninstall

```bash
oc delete -n $NS -f whisper-stt.yaml -f ministral-llm.yaml -f serving-runtime.yaml
```

(`../full-uninstall.sh` removes these along with the app.)

## Wire the web UI

Point the `smart-voice-assistant` ConfigMap at the two services (in-cluster svc
URLs, port **8080**):

```bash
oc set data configmap/smart-voice-assistant-config -n $NS \
  SVA_STT_MODEL=whisper-large-v3 \
  SVA_STT_ENDPOINT=http://whisper-large-v3-predictor.$NS.svc.cluster.local:8080/v1 \
  SVA_LLM_MODEL=ministral-3-3b-instruct \
  SVA_LLM_ENDPOINT=http://ministral-3-3b-instruct-predictor.$NS.svc.cluster.local:8080/v1
oc rollout restart deploy/smart-voice-assistant -n $NS
```

## Notes / variants

- **Lighter STT:** swap the Whisper `storageUri` to
  `…modelcar-catalog:whisper-large-v3-fp8-dynamic` (FP8, needs a compute-capability
  ≥ 8.9 GPU — Ada/Hopper such as L4/L40S/H100).
- **Transcription 404:** if `/v1/audio/transcriptions` isn't exposed on your vLLM
  build, uncomment `args: ["--task=transcription"]` in `whisper-stt.yaml`.
- **Auth:** these deploy with `enable-auth: "false"` for in-cluster use. For
  token-protected access set it `"true"` and put the token in `SVA_*_TOKEN`.
- **Browse the catalog:** other models (Granite, Gemma, GPT-OSS, Mistral-7B, …)
  are in the same catalog — see `quay.io/redhat-ai-services/modelcar-catalog` tags.
