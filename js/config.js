/* ============================================================
   config.js — load/save the app configuration.

   Order of truth:
     1. Backend  (server.py: GET/POST /api/config → config.yaml)
     2. localStorage fallback (when opened as a bare file://)
   The UI is pure HTML/JS/CSS; the backend is an optional thin
   persistence shim so "save to a yaml file" actually happens.
   ============================================================ */

const LS_KEY = 'sva.config.v1';

const DEFAULT_CONFIG = {
  branding: {
    app_title: 'Smart Voice Assistant',
    logo: ''                       // data URI; empty → built-in Red Hat mark
  },
  services: {
    stt: {
      name: 'redhataiwhisper-large-v3-turbo',
      endpoint: 'http://redhataiwhisper-large-v3-turbo-predictor.genai.svc.cluster.local:8080/v1',
      token: ''
    },
    llm: {
      name: 'redhataiministral-3-3b-instruc',
      endpoint: 'http://redhataiministral-3-3b-instruc-predictor.genai.svc.cluster.local:8080/v1',
      token: ''
    },
    tts: {
      name: 'supertonic-3',
      endpoint: 'http://supertonic.genai.svc.cluster.local:7788/v1/tts',
      token: '',
      api: 'native',      // native (/v1/tts) | openai (/v1/audio/speech)
      format: 'wav',      // wav | flac | ogg
      speed: '1.0'
    }
  }
};

function deepMerge(base, over) {
  const out = Array.isArray(base) ? base.slice() : { ...base };
  for (const [k, v] of Object.entries(over || {})) {
    if (v && typeof v === 'object' && !Array.isArray(v) && typeof out[k] === 'object') {
      out[k] = deepMerge(out[k], v);
    } else if (v !== undefined) {
      out[k] = v;
    }
  }
  return out;
}

const Config = {
  hasBackend: false,

  async load() {
    // Try backend first.
    try {
      const res = await fetch('/api/config', { cache: 'no-store' });
      if (res.ok) {
        const data = await res.json();
        this.hasBackend = true;
        return deepMerge(DEFAULT_CONFIG, data || {});
      }
    } catch (_) { /* file:// or server down → fall through */ }

    // localStorage fallback.
    try {
      const raw = localStorage.getItem(LS_KEY);
      if (raw) return deepMerge(DEFAULT_CONFIG, JSON.parse(raw));
    } catch (_) { /* ignore */ }

    return deepMerge(DEFAULT_CONFIG, {});
  },

  /**
   * Persist config. Returns { ok, mode } where mode is
   * 'yaml' (written server-side) or 'download' (browser fallback).
   */
  async save(cfg) {
    // Always keep a live copy locally so the home page reads it instantly.
    try { localStorage.setItem(LS_KEY, JSON.stringify(cfg)); } catch (_) {}

    // Try the backend (writes config.yaml on disk).
    try {
      const res = await fetch('/api/config', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(cfg)
      });
      if (res.ok) return { ok: true, mode: 'yaml' };
    } catch (_) { /* fall through to download */ }

    // No backend: hand the user a config.yaml to save.
    this.download(cfg);
    return { ok: true, mode: 'download' };
  },

  download(cfg) {
    const text = window.YAML.dump(cfg) + '\n';
    const blob = new Blob([text], { type: 'text/yaml' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = 'config.yaml';
    document.body.appendChild(a);
    a.click();
    a.remove();
    URL.revokeObjectURL(url);
  },

  parseYaml(text) {
    return deepMerge(DEFAULT_CONFIG, window.YAML.parse(text));
  }
};

if (typeof window !== 'undefined') {
  window.Config = Config;
  window.DEFAULT_CONFIG = DEFAULT_CONFIG;
}
