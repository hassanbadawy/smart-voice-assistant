/* ============================================================
   llm.js — reply generation (genai Ministral 3 3B Instruct).

   Posts an OpenAI chat payload to the same-origin /api/llm proxy,
   which relays to /v1/chat/completions. In AI-Agent mode the reply
   is constrained to the customer's language (targetLang) so it can
   be spoken back by TTS.

     LLM.reply(userText, { sourceLang, targetLang, mode }) -> Promise<{ text, lang }>
   ============================================================ */

window.LLM = {
  async reply(userText, { sourceLang = 'auto', targetLang = 'en', mode = 'ai' } = {}) {
    const cfg = (await Config.load()).services.llm;
    const langName =
      (window.SUPERTONIC_LANGS.find(l => l.code === targetLang) || {}).name || targetLang;

    const sys =
      `You are a helpful contact-centre voice assistant. ` +
      `Reply ONLY in ${langName}. Keep it to 1–2 short sentences suitable for ` +
      `text-to-speech. No emojis, no markdown, no lists.`;

    const res = await fetch('/api/llm', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: cfg.name,
        messages: [
          { role: 'system', content: sys },
          { role: 'user', content: userText }
        ],
        temperature: 0.3,
        max_tokens: 200
      })
    });
    if (!res.ok) {
      let msg = `LLM failed (HTTP ${res.status})`;
      try { const j = await res.json(); msg = j.error?.message || j.error || msg; } catch (_) {}
      throw new Error(msg);
    }
    const j = await res.json();
    const text = (j.choices && j.choices[0] && j.choices[0].message.content || '').trim();
    return { text, lang: targetLang };
  }
};
