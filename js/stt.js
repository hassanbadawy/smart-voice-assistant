/* ============================================================
   stt.js — Speech-to-Text (genai Whisper large-v3-turbo).

   Sends the recorded audio to the same-origin /api/stt proxy,
   which relays it to the OpenAI-compatible Whisper endpoint
   (/v1/audio/transcriptions) configured in Settings.

     STT.transcribe(audioBlob, { lang }) -> Promise<{ text, lang }>
   ============================================================ */

window.STT = {
  async transcribe(audioBlob, { lang = 'auto' } = {}) {
    const cfg = (await Config.load()).services.stt;
    const form = new FormData();
    form.append('file', audioBlob, 'audio.webm');
    form.append('model', cfg.name || 'whisper');
    form.append('response_format', 'json');
    if (lang && lang !== 'auto') form.append('language', lang);

    // NOTE: let the browser set the multipart Content-Type (with boundary).
    const res = await fetch('/api/stt', { method: 'POST', body: form });
    if (!res.ok) {
      let msg = `STT failed (HTTP ${res.status})`;
      try { const j = await res.json(); msg = j.error || j.message || msg; } catch (_) {}
      throw new Error(msg);
    }
    const j = await res.json();
    return { text: (j.text || '').trim(), lang: j.language || lang };
  }
};
