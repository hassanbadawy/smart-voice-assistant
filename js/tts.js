/* ============================================================
   tts.js — Text-to-Speech client (Supertonic 3).

   Talks to the same-origin /api/tts proxy in server.py, which
   forwards to the configured Supertonic endpoint. Handles one
   playback at a time.

   Public API:
     TTS.synthesize(text, { lang, voice, signal }) -> Promise<Blob>
     TTS.speak(text, { lang, voice }) -> Promise<HTMLAudioElement>
     TTS.stop()
   ============================================================ */

const TTS = {
  current: null,        // currently-playing HTMLAudioElement
  _url: null,

  async synthesize(text, { lang = 'en', voice = 'M1', signal } = {}) {
    const res = await fetch('/api/tts', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ text, lang, voice }),
      signal
    });
    if (!res.ok) {
      let msg = `TTS request failed (HTTP ${res.status})`;
      try { const j = await res.json(); if (j && j.error) msg = j.error; } catch (_) {}
      throw new Error(msg);
    }
    return await res.blob();
  },

  async speak(text, opts = {}) {
    this.stop();
    const blob = await this.synthesize(text, opts);
    const url = URL.createObjectURL(blob);
    const audio = new Audio(url);
    this.current = audio;
    this._url = url;
    const cleanup = () => {
      if (this._url === url) { URL.revokeObjectURL(url); this._url = null; }
      if (this.current === audio) this.current = null;
    };
    audio.addEventListener('ended', cleanup);
    audio.addEventListener('error', cleanup);
    await audio.play();
    return audio;
  },

  stop() {
    if (this.current) {
      try { this.current.pause(); } catch (_) {}
      this.current = null;
    }
    if (this._url) { URL.revokeObjectURL(this._url); this._url = null; }
  },

  get playing() { return !!this.current; }
};

if (typeof window !== 'undefined') window.TTS = TTS;
