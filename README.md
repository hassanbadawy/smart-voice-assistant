# Smart Voice Assistant

A multilingual voice-assistant UI for a **Support ⇄ Customer** contact-centre flow —
Support can answer as an **AI Agent** (replies in the customer's language) or as a
**Human** (with inline translation). Built with plain **HTML / CSS / JS**.

Being rebuilt in three phases:

| Phase | Scope | Status |
|-------|-------|--------|
| **1** | UI — two-panel layout, AI/Human modes, record state + live mic VU meter, settings page, YAML config | ✅ done |
| **2** | Push-and-talk — capture audio → STT → LLM → **TTS (Supertonic 3)** | 🟡 TTS done; STT/LLM = your part |
| **3** | LiveKit real-time media plane | ⏳ later |

## Phase 2 — TTS (Supertonic 3)

The TTS half is complete and multilingual (Supertonic 3, **31 languages**):

- **`POST /api/tts`** in `server.py` proxies `{text, lang, voice}` to Supertonic
  (native `/v1/tts` or OpenAI `/v1/audio/speech`, chosen in Settings). Keeps the
  token server-side and avoids browser CORS.
- **`js/tts.js`** — `TTS.speak(text, {lang, voice})` / `TTS.synthesize(...)`.
- **`js/langs.js`** — the 31 language codes + preset voices (M1/M3/M4/M5, F3/F4/F5).
- The voice-picker **Preview** button synthesises a localized sample live — the
  quickest way to confirm TTS end-to-end (no STT/LLM needed).
- ⚠️ Supertonic 3 does **not** support Urdu (Hindi + Indonesian are covered).

Run Supertonic locally: `pip install 'supertonic[serve]' && supertonic serve --port 7788`,
then set Settings → TTS endpoint to `http://127.0.0.1:7788/v1/tts`.

### Your part — STT + LLM (`js/stt.js`, `js/llm.js`)

`js/pipeline.js` already chains **record/upload → STT → LLM → TTS**. Implement the two
placeholder modules against the `genai` project models:

- **STT** — `RedHatAI/whisper-large-v3-turbo` (OpenAI `/v1/audio/transcriptions`)
- **LLM** — Ministral 3 3B Instruct (OpenAI `/v1/chat/completions`)

Each file has a commented reference implementation. **Reachability note:** when the app
runs *on the cluster*, the browser still can't reach `*.svc.cluster.local` directly — either
add `/api/stt` + `/api/llm` server-side proxies in `server.py` (mirror `/api/tts`) so calls
are same-origin, or expose Routes for Whisper/Ministral.

## Deploy on OpenShift

Declarative manifests + a one-shot script live in [`deploy/`](deploy/):

```bash
oc login ...
oc new-project voice-assistant
cd deploy && ./deploy.sh -n voice-assistant     # builds both images on-cluster, prints the URL
```

This builds the web UI (`Dockerfile`) and the Supertonic TTS backend
(`supertonic/Dockerfile`) on-cluster, applies `Deployment`/`Service`/`Route`
(edge-TLS → the mic works), and wires STT/LLM/TTS endpoints via a ConfigMap.

The image is **portable** — endpoints come from `SVA_*` env vars (see
`deploy/webui.yaml`), overridable in Settings at runtime. See
[`deploy/README.md`](deploy/README.md) for the manual path, the full env-var
list, and air-gap notes. Manifests are restricted-SCC compliant (non-root, no
privilege escalation, all caps dropped).

## Run

```bash
cd smart-voice-assistant
python3 server.py           # → http://127.0.0.1:8000  (default port 8000)
```

Then open **http://localhost:8000**. Running via the server (rather than opening
`index.html` directly) is recommended because:

1. `http://localhost` is a **secure context**, so the microphone works.
2. Settings are saved to a real **`config.yaml`** on disk (via `/api/config`).

No `pip install` needed — `server.py` is pure standard library (air-gap friendly).

## Pages

- **`index.html`** — the assistant. Left = **Support** (AI Agent / Human toggle,
  voice picker, press-to-talk). Right = **Customer** (language, press-to-talk,
  upload WAV/MP3). The header status pill shows **Connected** when the backend is up.
- **`settings.html`** — set the **STT / LLM / TTS** model name + endpoint + token,
  and replace the header **logo** / app title. Saves to `config.yaml`.

## Configuration

Settings persist to `config.yaml` (see `config.example.yaml` for the shape):

```yaml
branding:
  app_title: "Smart Voice Assistant"
  logo: ""                       # data URI; empty = built-in Red Hat mark
services:
  stt: { name: "…", endpoint: "…", token: "" }
  llm: { name: "…", endpoint: "…", token: "" }
  tts: { name: "…", endpoint: "…", token: "" }
```

If you open the pages **without** the server (`file://`), settings fall back to
`localStorage` and the **Save** button downloads a `config.yaml` you can drop next
to `server.py`. The **Import config.yaml** button reads one back.

## Phase 1 notes

- The **VU meter** is driven by the real microphone (Web Audio `AnalyserNode`).
- **Press to Speak** captures a clip via `MediaRecorder` but does **not** send it
  anywhere yet — Phase 2 wires it to the STT endpoint from settings.
- Tokens are stored in `config.yaml` in plain text (dev tool) — keep the file out
  of version control if it holds real credentials. A `.gitignore` is included.

## Files

```
smart-voice-assistant/
├── index.html          # home — Support ⇄ Customer
├── settings.html       # model + branding settings
├── server.py           # stdlib static server + /api/config (writes config.yaml)
├── config.example.yaml
├── css/styles.css
├── js/
│   ├── app.js          # home logic (modes, record, VU meter, status)
│   ├── settings.js     # settings form ↔ config
│   ├── config.js       # load/save (backend + localStorage fallback)
│   └── yaml.js         # minimal dependency-free YAML
└── assets/default-logo.svg
```
