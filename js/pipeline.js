/* ============================================================
   pipeline.js — routes a captured audio clip based on the
   current Support mode:

     AI Agent mode  → customer speaks → STT → LLM reply (customer's
                      language) → TTS.
     Human mode     → bidirectional translator: whoever speaks is
                      transcribed, translated into the OTHER side's
                      language, and spoken there. No LLM "answer".
   ============================================================ */

const Pipeline = {
  langOf(side) {
    const el = document.querySelector(side === 'customer' ? '#customerLang' : '#supportLang');
    return (el && el.value) || 'en';
  },
  voiceForSide(side) {
    // voice used when speaking TO this side
    const s = window.AppState || {};
    return side === 'customer' ? (s.customerVoice || 'F3') : (s.supportVoice || 'M1');
  },

  // dispatch based on mode + which side spoke
  handle(side, blob) {
    const mode = (window.AppState && window.AppState.mode) || 'ai';
    if (mode === 'human') return this.translate(side, blob);
    if (side === 'customer') return this.fromCustomer(blob);
  },

  // ---- AI Agent: customer → transcribe → reply in customer's language → speak ----
  async fromCustomer(audioBlob) {
    const lang = this.langOf('customer');
    const voice = (window.AppState && window.AppState.agentVoice) || 'M1';
    const say = window.toast || (() => {});

    let stt;
    try { stt = await window.STT.transcribe(audioBlob, { lang }); }
    catch (e) { say('STT error: ' + e.message, 'err'); this.setClip('customer', 'STT error'); return; }
    if (stt._placeholder || !stt.text) {
      say('STT not wired yet (js/stt.js).', ''); this.setClip('customer', 'STT not wired yet'); return;
    }
    this.setClip('customer', 'Heard: ' + stt.text);

    let llm;
    try { llm = await window.LLM.reply(stt.text, { sourceLang: stt.lang, targetLang: lang, mode: 'ai' }); }
    catch (e) { say('LLM error: ' + e.message, 'err'); return; }
    if (llm._placeholder || !llm.text) {
      say('LLM not wired yet (js/llm.js).', ''); return;
    }
    this.setClip('customer', '💬 ' + llm.text);
    try { await window.TTS.speak(llm.text, { lang: llm.lang || lang, voice }); }
    catch (e) { say('TTS error: ' + e.message, 'err'); }
  },

  // ---- Human mode: translate whoever spoke into the other side's language ----
  async translate(fromSide, audioBlob) {
    const toSide = fromSide === 'customer' ? 'support' : 'customer';
    const fromLang = this.langOf(fromSide);
    const toLang = this.langOf(toSide);
    const voice = this.voiceForSide(toSide);
    const say = window.toast || (() => {});

    let stt;
    try { stt = await window.STT.transcribe(audioBlob, { lang: fromLang }); }
    catch (e) { say('STT error: ' + e.message, 'err'); this.setClip(fromSide, 'STT error'); return; }
    if (stt._placeholder || !stt.text) {
      say('STT not wired yet (js/stt.js).', ''); this.setClip(fromSide, 'STT not wired yet'); return;
    }
    this.setClip(fromSide, 'Heard: ' + stt.text);

    let out = stt.text;
    if (fromLang !== toLang && fromLang !== 'na' && toLang !== 'na') {
      this.setClip(toSide, 'Translating…');
      try { out = (await window.LLM.translate(stt.text, { fromLang, toLang })).text; }
      catch (e) { say('Translation error: ' + e.message, 'err'); this.setClip(toSide, 'translation error'); return; }
    }
    this.setClip(toSide, '🌐 ' + out);
    try { await window.TTS.speak(out, { lang: toLang, voice }); }
    catch (e) { say('TTS error: ' + e.message, 'err'); }
  },

  setClip(side, text) {
    const el = document.querySelector(side === 'customer' ? '#customerClip' : '#supportClip');
    if (el) el.textContent = text;
  }
};

if (typeof window !== 'undefined') window.Pipeline = Pipeline;
