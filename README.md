# Smart Voice Assistant

A multilingual **Support ⇄ Customer** contact-centre voice assistant. Support can
either be an **AI Agent** that answers in the customer's language, or a **Human**
with the AI acting as a **live bidirectional voice translator** between the two
sides. Plain **HTML / CSS / JS** front-end + a dependency-free stdlib Python
server, deployable on OpenShift.

**Pipeline:** microphone → **STT** (Whisper) → **LLM / translate** (Ministral) →
**TTS** (Supertonic 3, 31 languages) → audio back. The browser talks only to the
app's own server, which proxies to the models (`/api/stt`, `/api/llm`,
`/api/tts`) — keeping tokens server-side and avoiding CORS.

| Mode | What happens |
|------|--------------|
| **AI Agent** | Customer speaks → transcribed → LLM replies **in the customer's language** → spoken back |
| **Human** | Each side's speech is transcribed, **translated into the other side's language**, and spoken there — no LLM "answer", pure translation |

## Quick start (local)

```bash
python3 server.py            # → http://127.0.0.1:8000  (stdlib only, no pip install)
```

Open **http://localhost:8000** (serving over `http://localhost` gives a secure
context, so the mic works, and Settings persist to `config.yaml`). Point the
STT/LLM/TTS endpoints at your services in **Settings**, or run Supertonic locally:

```bash
pip install 'supertonic[serve]' && supertonic serve --port 7788
```

## Deploy on OpenShift

The whole stack — models, TTS, and web UI — installs from the CLI. See
[`deploy/README.md`](deploy/README.md) for the full guide.

```bash
oc login ... && oc new-project voice-assistant
cd deploy
./full-install.sh -n voice-assistant     # models + Supertonic + web UI, wired + tested
```

`full-install.sh` preflights the cluster (RHOAI, pull secret, GPU
schedulability), deploys **Whisper + Ministral** from the public Red Hat AI
**ModelCar catalog** on KServe/vLLM, builds the **Supertonic** TTS backend and the
**web UI** on-cluster, wires everything, and runs an end-to-end **component test**
(Web UI / TTS / LLM / STT) before printing a software + hardware summary.

| Script | Does |
|--------|------|
| `full-install.sh` | Models + TTS + web UI, wired and tested |
| `app-install.sh` | TTS + web UI only (bring your own STT/LLM) |
| `full-uninstall.sh` / `app-uninstall.sh` | Tear down (with / without models) |
| `status.sh` | One-shot install status (cron-able) |
| `gpu-status.sh` | Cluster GPU inventory — specs, EMPTY/ENGAGED state, live utilization |

Installs are **idempotent and skip healthy components** (a model already `Ready`
isn't re-pulled); `--force` rebuilds everything. The web-UI image is portable —
endpoints come from `SVA_*` env / a ConfigMap, so the same image runs on any
cluster. Manifests are restricted-SCC compliant; the Route is edge-TLS (HTTPS) so
the browser mic works.

## Pages

- **`index.html`** — the assistant. Left = **Support** (AI Agent / Human toggle,
  voice picker, press-to-talk), right = **Customer** (language, press-to-talk,
  upload WAV/MP3). Header pill shows backend connectivity.
- **`settings.html`** — STT / LLM / TTS model name + endpoint + token, TTS API
  style/format, and the header logo / app title. Saves to `config.yaml`.

## Configuration

Config precedence: **`config.yaml` (Settings) > `SVA_*` env vars > built-in
defaults**. Shape (`config.example.yaml`):

```yaml
branding:
  app_title: "Smart Voice Assistant"
  logo: ""                       # data URI; empty = built-in mark
services:
  stt: { name: "whisper-large-v3",        endpoint: "…/v1", token: "" }
  llm: { name: "ministral-3-3b-instruct", endpoint: "…/v1", token: "" }
  tts: { name: "supertonic-3", endpoint: "…/v1/tts", api: "native", format: "wav" }
```

Opened as a bare `file://`, Settings fall back to `localStorage` and **Save**
downloads a `config.yaml` (re-load it with **Import config.yaml**).

⚠️ Supertonic 3 covers **31 languages** (incl. Arabic, Hindi, Indonesian) but
**not Urdu**. Tokens live in `config.yaml` in plain text — it's `.gitignore`d.

## Structure

```
smart-voice-assistant/
├── index.html  settings.html        # UI
├── css/styles.css
├── js/
│   ├── app.js        # home logic — modes, record, VU meter, status
│   ├── pipeline.js   # record/upload → STT → LLM/translate → TTS
│   ├── stt.js llm.js tts.js         # service clients (call the server proxies)
│   ├── langs.js      # 31 Supertonic languages + voices
│   ├── settings.js config.js yaml.js
├── server.py         # static + /api/{config,tts,stt,llm}; env-driven config
├── Dockerfile        # web-UI image (UBI9 Python)
├── supertonic/       # Supertonic 3 TTS build context
└── deploy/           # OpenShift install/uninstall/status/gpu scripts + manifests
    ├── full-install.sh app-install.sh full/app-uninstall.sh status.sh gpu-status.sh
    ├── lib.sh        # shared: preflight, deploy, tests, summary
    ├── webui.yaml supertonic.yaml
    └── models/       # Whisper + Ministral KServe manifests (+ README)
```

## Roadmap

| Phase | Scope | Status |
|-------|-------|--------|
| 1 | UI — two-panel, AI/Human modes, live mic VU meter, settings, YAML config | ✅ |
| 2 | Push-and-talk — STT → LLM/translate → TTS; both modes; OpenShift deploy | ✅ |
| 3 | LiveKit real-time media plane | ⏳ |
