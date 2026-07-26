/* ============================================================
   pipeline.js — orchestrates one turn:
     audio → STT (your part) → LLM (your part) → TTS (Supertonic, done).

   The moment js/stt.js and js/llm.js are implemented, recorded/
   uploaded customer audio flows straight into spoken replies.
   ============================================================ */

const Pipeline = {
  // customer spoke → AI agent answers in the customer's language, spoken via TTS
  async fromCustomer(audioBlob) {
    const lang = document.querySelector('#customerLang')?.value || 'en';
    const voice = (window.AppState && window.AppState.agentVoice) || 'M1';
    const say = window.toast || (() => {});

    let stt;
    try {
      stt = await window.STT.transcribe(audioBlob, { lang: 'auto' });
    } catch (e) {
      say('STT error: ' + e.message, 'err');
      return;
    }
    if (stt._placeholder || !stt.text) {
      say('STT not wired yet (js/stt.js). TTS is ready — try Preview.', '');
      this.setClip('customer', 'STT not wired yet — add js/stt.js');
      return;
    }
    this.showTranscript('customer', stt.text);

    let llm;
    try {
      llm = await window.LLM.reply(stt.text, { sourceLang: stt.lang, targetLang: lang, mode: 'ai' });
    } catch (e) {
      say('LLM error: ' + e.message, 'err');
      return;
    }
    if (llm._placeholder || !llm.text) {
      say('LLM not wired yet (js/llm.js). Then replies auto-speak.', '');
      this.setClip('customer', 'LLM not wired yet — add js/llm.js');
      return;
    }

    try {
      await window.TTS.speak(llm.text, { lang: llm.lang || lang, voice });
    } catch (e) {
      say('TTS error: ' + e.message, 'err');
    }
  },

  showTranscript(side, text) {
    const el = document.querySelector(side === 'customer' ? '#customerClip' : '#supportClip');
    if (el) el.innerHTML = `Heard: <b>${text.replace(/</g, '&lt;')}</b>`;
  },

  setClip(side, text) {
    const el = document.querySelector(side === 'customer' ? '#customerClip' : '#supportClip');
    if (el) el.textContent = text;
  }
};

if (typeof window !== 'undefined') window.Pipeline = Pipeline;
