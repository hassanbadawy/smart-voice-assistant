#!/usr/bin/env python3
"""
Smart Voice Assistant — tiny static server + config persistence.

Pure Python standard library (no pip install, air-gap friendly). It:
  * serves the UI (index.html, settings.html, css/, js/, assets/)
  * GET  /api/config  -> reads config.yaml, returns JSON
  * POST /api/config  -> writes config.yaml from JSON body
  * GET  /api/health  -> {"ok": true}  (drives the Connected pill)

Run:  python3 server.py [--port 8000]
Then open http://localhost:8000

Phase 1 does not call the STT/LLM/TTS services — those endpoints are
just stored here so Phase 2 can use them.
"""

import argparse
import json
import os
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(ROOT, "config.yaml")

# Portable defaults. Deployment wiring (cluster svc URLs) comes from env vars
# (see ENV_MAP) or is set in Settings. Precedence: config.yaml > env > defaults.
# In-cluster service URLs for the default `voice-assistant` namespace. These are
# what full-install.sh wires into the ConfigMap, baked in so the image works
# out of the box without wiring. Deploying to a DIFFERENT namespace? Override
# SVA_{STT,LLM,TTS}_ENDPOINT (the install scripts do this automatically) — the
# `.voice-assistant.` segment is not portable on its own.
DEFAULT_CONFIG = {
    "branding": {"app_title": "Smart Voice Assistant", "logo": ""},
    "services": {
        "stt": {
            "name": "whisper-large-v3",
            "endpoint": "http://whisper-large-v3-predictor.voice-assistant.svc.cluster.local:8080/v1",
            "token": "",
        },
        "llm": {
            "name": "ministral-3-3b-instruct",
            "endpoint": "http://ministral-3-3b-instruct-predictor.voice-assistant.svc.cluster.local:8080/v1",
            "token": "",
        },
        # TTS = Supertonic 3 (31 languages), native /v1/tts.
        "tts": {
            "name": "supertonic-3",
            "endpoint": "http://supertonic.voice-assistant.svc.cluster.local:7788/v1/tts",
            "token": "",
            "api": "native",   # native (/v1/tts) | openai (/v1/audio/speech)
            "format": "wav",   # wav | flac | ogg  (Supertonic does NOT do mp3)
            "speed": "1.0",
        },
    },
}

# Env var → config path. Lets the same image be wired per-cluster without a rebuild.
ENV_MAP = {
    "SVA_APP_TITLE":    ("branding", "app_title"),
    "SVA_STT_MODEL":    ("services", "stt", "name"),
    "SVA_STT_ENDPOINT": ("services", "stt", "endpoint"),
    "SVA_STT_TOKEN":    ("services", "stt", "token"),
    "SVA_LLM_MODEL":    ("services", "llm", "name"),
    "SVA_LLM_ENDPOINT": ("services", "llm", "endpoint"),
    "SVA_LLM_TOKEN":    ("services", "llm", "token"),
    "SVA_TTS_MODEL":    ("services", "tts", "name"),
    "SVA_TTS_ENDPOINT": ("services", "tts", "endpoint"),
    "SVA_TTS_TOKEN":    ("services", "tts", "token"),
    "SVA_TTS_API":      ("services", "tts", "api"),
    "SVA_TTS_FORMAT":   ("services", "tts", "format"),
    "SVA_TTS_SPEED":    ("services", "tts", "speed"),
}


def env_config():
    """Build a partial config from SVA_* environment variables."""
    out = {}
    for var, path in ENV_MAP.items():
        val = os.environ.get(var)
        if val is None:
            continue
        node = out
        for key in path[:-1]:
            node = node.setdefault(key, {})
        node[path[-1]] = val
    return out

CONTENT_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".yaml": "text/yaml; charset=utf-8",
    ".ico": "image/x-icon",
}


# ----------------------------------------------------------------------
# Minimal YAML (nested maps of string scalars) — mirrors js/yaml.js.
# ----------------------------------------------------------------------
def yaml_dump(obj, indent=0):
    pad = "  " * indent
    lines = []
    for key, val in obj.items():
        if isinstance(val, dict):
            lines.append(f"{pad}{key}:")
            inner = yaml_dump(val, indent + 1)
            if inner:
                lines.append(inner)
        else:
            s = "" if val is None else str(val)
            s = s.replace("\\", "\\\\").replace('"', '\\"')
            lines.append(f'{pad}{key}: "{s}"')
    return "\n".join(lines)


def _scalar(rest):
    """Parse a scalar value, respecting quotes and stripping inline comments."""
    rest = rest.strip()
    if rest.startswith('"'):
        out, i = [], 1
        while i < len(rest):
            c = rest[i]
            if c == "\\" and i + 1 < len(rest):
                out.append(rest[i + 1]); i += 2; continue
            if c == '"':
                return "".join(out)
            out.append(c); i += 1
        return "".join(out)
    if rest.startswith("'"):
        out, i = [], 1
        while i < len(rest):
            if rest[i] == "'":
                if i + 1 < len(rest) and rest[i + 1] == "'":
                    out.append("'"); i += 2; continue
                return "".join(out)
            out.append(rest[i]); i += 1
        return "".join(out)
    # unquoted → drop an inline comment
    h = rest.find(" #")
    if h != -1:
        rest = rest[:h]
    return rest.strip()


def yaml_load(text):
    root = {}
    stack = [(-1, root)]  # (indent, node)
    for raw_line in text.splitlines():
        if not raw_line.strip() or raw_line.strip().startswith("#"):
            continue
        indent = len(raw_line) - len(raw_line.lstrip(" "))
        line = raw_line.strip()
        if ":" not in line:
            continue
        key, _, rest = line.partition(":")
        key = key.strip()
        rest_stripped = rest.strip()
        is_map = rest_stripped == "" or rest_stripped.startswith("#")
        while len(stack) > 1 and indent <= stack[-1][0]:
            stack.pop()
        parent = stack[-1][1]
        if is_map:
            child = {}
            parent[key] = child
            stack.append((indent, child))
        else:
            parent[key] = _scalar(rest)
    return root


def deep_merge(base, over):
    out = dict(base)
    for k, v in (over or {}).items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = deep_merge(out[k], v)
        elif v is not None:
            out[k] = v
    return out


def base_config():
    """DEFAULT_CONFIG with SVA_* env overrides applied (env wins over defaults)."""
    return deep_merge(DEFAULT_CONFIG, env_config())


def read_config():
    """Precedence: config.yaml (Settings) > env vars > built-in defaults."""
    base = base_config()
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH, "r", encoding="utf-8") as fh:
                return deep_merge(base, yaml_load(fh.read()))
        except Exception as exc:  # noqa: BLE001
            print(f"[warn] could not read config.yaml: {exc}")
    return base


def write_config(cfg):
    merged = deep_merge(base_config(), cfg)
    with open(CONFIG_PATH, "w", encoding="utf-8") as fh:
        fh.write(yaml_dump(merged) + "\n")
    return merged


# ----------------------------------------------------------------------
# TTS proxy — forwards {text, lang, voice} to Supertonic 3.
# Keeps the endpoint token server-side and dodges browser CORS.
# ----------------------------------------------------------------------
_FMT_CTYPE = {"wav": "audio/wav", "flac": "audio/flac", "ogg": "audio/ogg"}


def synth_tts(cfg_tts, text, lang, voice):
    """Call Supertonic and return (audio_bytes, content_type). Raises on error."""
    endpoint = (cfg_tts.get("endpoint") or "http://127.0.0.1:7788/v1/tts").rstrip("/")
    api = (cfg_tts.get("api") or "native").lower()
    fmt = (cfg_tts.get("format") or "wav").lower()
    try:
        speed = float(cfg_tts.get("speed") or 1.0)
    except (TypeError, ValueError):
        speed = 1.0

    if api == "openai":
        url = endpoint if "/audio/speech" in endpoint else endpoint + "/v1/audio/speech"
        body = {
            "model": cfg_tts.get("name") or "supertonic-3",
            "input": text,
            "voice": voice,
            "response_format": fmt,
            "speed": speed,
        }
    else:  # native /v1/tts — documented fields only: text, voice, lang
        url = endpoint if "/v1/tts" in endpoint else endpoint + "/v1/tts"
        body = {"text": text, "voice": voice, "lang": lang}

    req = urllib.request.Request(
        url, data=json.dumps(body).encode("utf-8"), method="POST"
    )
    req.add_header("Content-Type", "application/json")
    token = cfg_tts.get("token")
    if token:
        req.add_header("Authorization", "Bearer " + token)

    with urllib.request.urlopen(req, timeout=45) as resp:
        ctype = resp.headers.get("Content-Type") or _FMT_CTYPE.get(fmt, "audio/wav")
        return resp.read(), ctype


def relay(cfg_svc, subpath, content_type, body, timeout=120):
    """Passthrough proxy to an OpenAI-compatible service (STT / LLM).
    Relays the raw body + content-type, adds Bearer auth, rewrites the URL.
    Returns (bytes, status, content_type)."""
    base = (cfg_svc.get("endpoint") or "").rstrip("/")
    if not base:
        raise ValueError("endpoint not configured")
    req = urllib.request.Request(base + subpath, data=body, method="POST")
    if content_type:
        req.add_header("Content-Type", content_type)
    token = cfg_svc.get("token")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read(), resp.status, resp.headers.get("Content-Type", "application/json")


# ----------------------------------------------------------------------
# HTTP handler
# ----------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body=b"", ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _json(self, code, obj):
        self._send(code, json.dumps(obj).encode("utf-8"), "application/json")

    # ---- GET ----
    def do_GET(self):
        path = self.path.split("?", 1)[0]

        if path == "/api/health":
            return self._json(200, {"ok": True})
        if path == "/api/config":
            return self._json(200, read_config())

        return self._serve_static(path)

    # ---- POST ----
    def do_POST(self):
        path = self.path.split("?", 1)[0]
        length = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(length) if length else b""
        ctype_in = self.headers.get("Content-Type", "")

        # --- STT / LLM passthrough proxies (raw relay, no JSON parse) ---
        if path in ("/api/stt", "/api/llm"):
            svc = "stt" if path == "/api/stt" else "llm"
            subpath = "/audio/transcriptions" if svc == "stt" else "/chat/completions"
            cfg_svc = read_config()["services"][svc]
            if not cfg_svc.get("endpoint"):
                return self._json(400, {"error": f"{svc.upper()} endpoint not configured — set it in Settings"})
            try:
                data, status, ctype = relay(cfg_svc, subpath, ctype_in, raw)
            except urllib.error.HTTPError as exc:
                return self._send(exc.code, exc.read(), exc.headers.get("Content-Type", "application/json"))
            except urllib.error.URLError as exc:
                return self._json(502, {"error": f"cannot reach {svc.upper()}: {exc.reason}"})
            except Exception as exc:  # noqa: BLE001
                return self._json(500, {"error": f"{svc.upper()} failed: {exc}"})
            return self._send(status, data, ctype)

        # --- JSON endpoints ---
        try:
            payload = json.loads(raw or b"{}")
        except Exception:  # noqa: BLE001
            return self._json(400, {"error": "invalid JSON body"})

        if path == "/api/config":
            try:
                saved = write_config(payload)
            except Exception as exc:  # noqa: BLE001
                return self._json(500, {"error": f"could not write config.yaml: {exc}"})
            print(f"[ok] wrote {CONFIG_PATH}")
            return self._json(200, {"ok": True, "config": saved})

        if path == "/api/tts":
            text = (payload.get("text") or "").strip()
            if not text:
                return self._json(400, {"error": "missing 'text'"})
            lang = payload.get("lang") or "en"
            voice = payload.get("voice") or "M1"
            cfg_tts = read_config()["services"]["tts"]
            if not cfg_tts.get("endpoint"):
                return self._json(400, {"error": "TTS endpoint not configured — set it in Settings"})
            try:
                audio, ctype = synth_tts(cfg_tts, text, lang, voice)
            except urllib.error.HTTPError as exc:
                detail = exc.read().decode("utf-8", "replace")[:400]
                return self._json(exc.code, {"error": f"TTS service {exc.code}: {detail}"})
            except urllib.error.URLError as exc:
                return self._json(502, {"error": f"cannot reach TTS service: {exc.reason}"})
            except Exception as exc:  # noqa: BLE001
                return self._json(500, {"error": f"TTS failed: {exc}"})
            return self._send(200, audio, ctype)

        return self._json(404, {"error": "not found"})

    # ---- static files ----
    def _serve_static(self, path):
        if path in ("/", ""):
            path = "/index.html"
        rel = path.lstrip("/")
        full = os.path.normpath(os.path.join(ROOT, rel))
        # prevent path traversal outside ROOT
        if not full.startswith(ROOT) or not os.path.isfile(full):
            return self._send(404, b"Not found", "text/plain; charset=utf-8")
        ext = os.path.splitext(full)[1].lower()
        ctype = CONTENT_TYPES.get(ext, "application/octet-stream")
        with open(full, "rb") as fh:
            body = fh.read()
        return self._send(200, body, ctype)

    # quieter logging
    def log_message(self, fmt, *args):
        if "/api/" in (self.path or ""):
            super().log_message(fmt, *args)


def main():
    parser = argparse.ArgumentParser(description="Smart Voice Assistant server")
    parser.add_argument("--port", type=int, default=int(os.environ.get("PORT", 8000)))
    parser.add_argument("--host", default=os.environ.get("HOST", "127.0.0.1"))
    args = parser.parse_args()

    # No config.yaml is created on startup — config is env-driven until a user
    # saves in Settings (which writes config.yaml). Report the effective wiring.
    cfg = read_config()["services"]
    for svc in ("stt", "llm", "tts"):
        print(f"[config] {svc}: {cfg[svc].get('endpoint') or '(unset — configure in Settings)'}")

    srv = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"Smart Voice Assistant → http://{args.host}:{args.port}")
    print("Press Ctrl+C to stop.")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nbye.")
        srv.shutdown()


if __name__ == "__main__":
    main()
