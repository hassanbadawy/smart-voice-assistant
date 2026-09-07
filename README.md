# Deploy a Multilingual AI Voice Assistant

Deploy an AI voice assistant that speaks 31 languages — answer customers with an AI agent or bridge human support with live voice translation on OpenShift.

## Table of Contents

- [Overview](#overview)
- [Detailed description](#detailed-description)
  - [See it in action](#see-it-in-action)
  - [Architecture diagrams](#architecture-diagrams)
- [Requirements](#requirements)
  - [Minimum hardware requirements](#minimum-hardware-requirements)
  - [Minimum software requirements](#minimum-software-requirements)
  - [Required user permissions](#required-user-permissions)
- [Deploy](#deploy)
  - [Prerequisites](#prerequisites)
  - [Installation](#installation)
  - [Validating the deployment](#validating-the-deployment)
  - [Delete](#delete)
- [Repository structure](#repository-structure)
- [References](#references)
- [Technical details](#technical-details)
  - [Modes](#modes)
  - [Configuration](#configuration)
  - [Quick start (local)](#quick-start-local)
  - [Roadmap](#roadmap)
- [Tags](#tags)

## Overview

Contact centres need to serve customers in their language, but hiring multilingual agents is expensive and doesn't scale. This quickstart deploys a voice assistant that handles 31 languages out of the box — either answering customers autonomously as an AI agent, or acting as a live voice translator between a human support agent and the customer. After deploying, you get a browser-based two-panel interface (Support + Customer) connected to an AI pipeline running entirely on your OpenShift cluster.

## Detailed description

Multilingual customer support is one of the highest-cost, hardest-to-staff functions in any contact centre. Customers expect to be served in their own language, yet finding agents who speak Arabic, Hindi, Indonesian, or Korean — let alone all 31 supported languages — is impractical. Traditional solutions rely on proprietary cloud translation APIs that route sensitive customer data through third-party services.

This quickstart solves the problem with two modes. In **AI Agent** mode, the customer speaks and the assistant transcribes their speech, generates an intelligent reply in the customer's language, and speaks it back — no human agent needed. In **Human** mode, a human support agent and the customer each speak their own language; the assistant transcribes, translates, and speaks the translation to the other side in real time — a live bidirectional voice translator with no LLM "answer" generated.

The pipeline chains three open-weight models: **Whisper large-v3** for speech-to-text, **Ministral 3B Instruct** for reply generation and translation, and **Supertonic 3** for text-to-speech across 31 languages. All models run on your own OpenShift cluster — Whisper and Ministral are served by KServe/vLLM on GPU, while Supertonic runs on CPU with ONNX. The browser-based UI talks only to a lightweight Python proxy server, which keeps API tokens server-side and avoids CORS. The entire stack deploys from a single CLI command.

### See it in action

![Application screenshot](docs/images/screenshot.png)

[Watch the video walkthrough](https://youtu.be/6KaspxeJ7MA?si=Hy6wii4N7MioH0sy)

### Architecture diagrams

![Architecture diagram](docs/images/architecture.png)

| Component | Role | Runtime | Endpoint |
|-----------|------|---------|----------|
| **Whisper large-v3** | Speech-to-Text | KServe / vLLM on GPU | `/v1/audio/transcriptions` |
| **Ministral 3B Instruct** | LLM (reply + translation) | KServe / vLLM on GPU | `/v1/chat/completions` |
| **Supertonic 3** | Text-to-Speech (31 languages) | ONNX on CPU | `/v1/tts` |
| **Web UI** | Static front-end + API proxy | Python 3.11 (stdlib only) | `/api/stt`, `/api/llm`, `/api/tts` |

The browser sends audio to the Web UI pod over HTTPS (edge-TLS Route). The Web UI proxies each API call to the corresponding model backend, keeping tokens server-side.

## Requirements

### Minimum hardware requirements

| Component | CPU (request / limit) | Memory (request / limit) | GPU |
|-----------|-----------------------|--------------------------|-----|
| Whisper large-v3 (STT) | 2 / 8 cores | 8 GiB / 24 GiB | 1x NVIDIA GPU (16 GB+ VRAM) |
| Ministral 3B (LLM) | 2 / 8 cores | 8 GiB / 24 GiB | 1x NVIDIA GPU (16 GB+ VRAM) |
| Supertonic 3 (TTS) | 2 / 8 cores | 1 GiB / 2 GiB | None (CPU-only) |
| Web UI | 50m / 500m | 128 MiB / 256 MiB | None |
| **Total** | **~6 cores request** | **~17 GiB request** | **2x NVIDIA GPU (16 GB+ VRAM each)** |

> **Note:** If you bring your own STT/LLM endpoints (using `app-install.sh`), GPU is not required on this cluster.

### Minimum software requirements

- **OpenShift Container Platform** 4.14 or later (tested with 4.20)
- **Red Hat OpenShift AI (RHOAI)** 2.19 or later with KServe enabled (tested with 3.5) — (`KServe` management state is `Managed` in the `DataScienceCluster` CR, see [Installing OpenShift AI components](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/installing_and_uninstalling_openshift_ai_self-managed/installing-and-deploying-openshift-ai_install#installing-and-managing-openshift-ai-components_component-install))
- **NVIDIA GPU Operator** (for GPU-served models)
- **`oc` CLI** 4.14 or later, authenticated to the cluster

### Required user permissions

This quickstart can be deployed by any user with:

- Permission to create projects/namespaces
- Permission to deploy applications (`oc apply`, `oc start-build`)
- Node-reader access (the install script reads GPU node status for preflight checks)

## Deploy

### Prerequisites

Before deploying, ensure you have:

- Access to a Red Hat OpenShift cluster with RHOAI and KServe installed
- `oc` CLI installed and authenticated (`oc login ...`)
- At least 2 NVIDIA GPUs (16 GB+ VRAM each) schedulable on the cluster (for the full stack)

### Installation

1. Clone the repository:

   ```bash
   git clone https://github.com/mamurak/smart-voice-assistant.git
   cd smart-voice-assistant
   ```

2. Create a new OpenShift project:

   ```bash
   oc new-project voice-assistant
   ```

3. Run the full installer:

   ```bash
   cd deploy
   ./full-install.sh -n voice-assistant
   ```

   The script will:
   - **Preflight** the cluster (RHOAI, pull secrets, GPU schedulability)
   - **Deploy models** — Whisper and Ministral from the Red Hat AI ModelCar catalog
   - **Build and deploy** the Supertonic TTS backend and the Web UI on-cluster
   - **Wire** all endpoints via ConfigMap
   - **Run component tests** (Web UI, TTS, LLM, STT)
   - **Print** the application URL and a hardware/software summary

   Components deploy in parallel by default (wall-clock = slowest component).

#### Alternative deployment options

**Bring your own STT/LLM** — deploy only the TTS backend and Web UI:

```bash
./app-install.sh -n voice-assistant
```

Then configure your STT/LLM endpoints in the Settings page or via `SVA_*` environment variables.

**Disconnected / registry-less clusters** — pre-build images and push to an external registry:

```bash
podman login quay.io
./build-push.sh -r quay.io/<your-org>
./full-install.sh -n voice-assistant --registry quay.io/<your-org>
```

See [`deploy/README.md`](deploy/README.md) for the full deployment guide, including flags, GPU details, monitoring, troubleshooting, and manual deployment.

### Validating the deployment

The installer runs a component test automatically. You can verify manually:

1. Check all pods are running:

   ```bash
   oc get pods -n voice-assistant
   ```

2. Get the application URL:

   ```bash
   echo "https://$(oc get route/smart-voice-assistant -n voice-assistant --template='{{.spec.host}}')"
   ```

3. Check install status anytime:

   ```bash
   cd deploy
   ./status.sh -n voice-assistant
   ```

### Delete

To completely remove the deployment:

```bash
cd deploy
./full-uninstall.sh -n voice-assistant    # removes everything (models + TTS + web UI)
./app-uninstall.sh  -n voice-assistant    # removes app only, keeps models
```

Optionally delete the project:

```bash
oc delete project voice-assistant
```

## Repository structure

```
smart-voice-assistant/
├── index.html  settings.html        # UI pages
├── css/styles.css                   # Styles (green + purple themes)
├── js/
│   ├── app.js                       # Home logic — modes, record, VU meter, status
│   ├── pipeline.js                  # Audio routing: STT → LLM/translate → TTS
│   ├── stt.js llm.js tts.js        # Service clients (call the server proxies)
│   ├── langs.js                     # 31 Supertonic languages + voices
│   └── settings.js config.js yaml.js
├── server.py                        # Static files + /api/{config,tts,stt,llm} proxy
├── Dockerfile / Containerfile       # Web UI image (UBI9 Python 3.11)
├── config.example.yaml              # Example configuration
├── LICENSE                          # Apache 2.0
├── docs/
│   └── images/                      # Architecture diagrams and screenshots
├── supertonic/                      # Supertonic 3 TTS build context
│   └── Dockerfile                   # TTS image (weights baked in for air-gap)
├── deploy/                          # OpenShift deployment
│   ├── full-install.sh / app-install.sh   # Install scripts
│   ├── full-uninstall.sh / app-uninstall.sh
│   ├── status.sh / gpu-status.sh    # Monitoring
│   ├── build-push.sh               # Pre-build images for disconnected clusters
│   ├── lib.sh                       # Shared library (preflight, deploy, tests)
│   ├── webui.yaml / supertonic.yaml # App manifests
│   └── models/                      # KServe InferenceService manifests
│       ├── serving-runtime.yaml     # Shared vLLM ServingRuntime
│       ├── whisper-stt.yaml         # Whisper large-v3
│       └── ministral-llm.yaml      # Ministral 3B Instruct
└── wiki/                            # Architecture, deployment, troubleshooting docs
```

## References

- [Whisper large-v3 model card](https://huggingface.co/openai/whisper-large-v3)
- [Ministral 3B Instruct model card](https://huggingface.co/mistralai/Ministral-3b-Instruct-2503)
- [Supertonic 3 model card](https://huggingface.co/Supertone/supertonic-3)
- [Red Hat AI ModelCar catalog](https://quay.io/organization/redhat-ai-services)
- [Red Hat OpenShift AI documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed)
- [Enabling the KServe component](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/installing_and_uninstalling_openshift_ai_self-managed/installing-and-deploying-openshift-ai_install#installing-and-managing-openshift-ai-components_component-install)
- [KServe documentation](https://kserve.github.io/website/)
- [Detailed deployment guide](deploy/README.md) — flags, GPU notes, monitoring, troubleshooting
- [Troubleshooting guide](wiki/troubleshooting.md) — root-caused production issues and fixes

## Technical details

### Modes

| Mode | What happens |
|------|--------------|
| **AI Agent** | Customer speaks → transcribed → LLM replies **in the customer's language** → spoken back |
| **Human** | Each side's speech is transcribed, **translated into the other side's language**, and spoken there — no LLM "answer", pure translation |

### Configuration

Config precedence: **`config.yaml` (Settings page) > `SVA_*` env vars > built-in defaults**.

```yaml
branding:
  app_title: "Smart Voice Assistant"
  logo: ""                       # data URI; empty = built-in mark
services:
  stt: { name: "whisper-large-v3",        endpoint: "…/v1", token: "" }
  llm: { name: "ministral-3-3b-instruct", endpoint: "…/v1", token: "" }
  tts: { name: "supertonic-3", endpoint: "…/v1/tts", api: "native", format: "wav" }
```

Supertonic 3 covers **31 languages** (incl. Arabic, Hindi, Indonesian) but **not Urdu**. Tokens live in `config.yaml` in plain text — the file is `.gitignore`d.

### Quick start (local)

```bash
python3 server.py            # → http://127.0.0.1:8000  (stdlib only, no pip install)
```

Open **http://localhost:8000**, then point the STT/LLM/TTS endpoints at your services in **Settings**, or run Supertonic locally:

```bash
pip install 'supertonic[serve]' && supertonic serve --port 7788
```

## Tags

- **Industry:** Telecommunications
- **Product:** Red Hat OpenShift AI
- **Use case:** Call Center Voice Assistant
