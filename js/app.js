/* ============================================================
   app.js — home page.
   Phase 2: TTS (Supertonic) is live via Preview + the pipeline;
   STT/LLM are wired in js/stt.js + js/llm.js (your part).
   Language + voice catalog comes from js/langs.js.
   ============================================================ */

const VOICES = window.SUPERTONIC_VOICES;
const LANGUAGES = window.SUPERTONIC_LANGS;

// shared app state (read by pipeline.js)
window.AppState = { agentVoice: 'F3' };

const $ = (sel, root = document) => root.querySelector(sel);

/* ---------- toast ---------- */
let toastTimer;
function toast(msg, kind = '') {
  const el = $('#toast');
  el.textContent = msg;
  el.className = 'toast show ' + kind;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (el.className = 'toast ' + kind), 2600);
}
window.toast = toast;

/* ---------- branding from config ---------- */
function applyBranding(cfg) {
  const title = cfg.branding?.app_title || 'Smart Voice Assistant';
  $('#appTitle').textContent = title;
  document.title = title;

  const holder = $('#brandLogo');
  const logo = cfg.branding?.logo;
  if (logo) {
    holder.innerHTML = '';
    const img = document.createElement('img');
    img.src = logo;
    img.alt = title + ' logo';
    holder.appendChild(img);
  } else {
    // built-in default mark
    const img = document.createElement('img');
    img.src = 'assets/default-logo.svg';
    img.alt = 'Red Hat';
    holder.appendChild(img);
  }
}

/* ---------- backend connection status ---------- */
async function refreshStatus() {
  const pill = $('#statusPill');
  const text = $('#statusText');
  try {
    const res = await fetch('/api/health', { cache: 'no-store' });
    if (res.ok) {
      pill.classList.add('is-online');
      text.textContent = 'Connected';
      return;
    }
  } catch (_) { /* offline */ }
  pill.classList.remove('is-online');
  text.textContent = 'Disconnected';
}

/* ---------- populate selects ---------- */
function fillSelect(el, items, getVal, getLabel, selected) {
  el.innerHTML = '';
  for (const it of items) {
    const opt = document.createElement('option');
    opt.value = getVal(it);
    opt.textContent = getLabel(it);
    if (getVal(it) === selected) opt.selected = true;
    el.appendChild(opt);
  }
}

/* ---------- support mode toggle ---------- */
function initModeToggle() {
  const aiBtn = $('#modeAi');
  const humanBtn = $('#modeHuman');
  const aiView = $('#aiView');
  const humanView = $('#humanView');

  function set(mode) {
    const ai = mode === 'ai';
    aiBtn.classList.toggle('is-on', ai);
    humanBtn.classList.toggle('is-on', !ai);
    aiBtn.setAttribute('aria-selected', String(ai));
    humanBtn.setAttribute('aria-selected', String(!ai));
    aiView.hidden = !ai;
    humanView.hidden = ai;
  }
  aiBtn.addEventListener('click', () => set('ai'));
  humanBtn.addEventListener('click', () => set('human'));
}

/* ---------- voice picker (live Supertonic preview) ---------- */
function initVoicePicker() {
  const sel = $('#voiceSelect');
  fillSelect(sel, VOICES, v => v.id, v => v.label, window.AppState.agentVoice);
  $('#voiceSelected').textContent = window.AppState.agentVoice;

  $('#selectVoice').addEventListener('click', () => {
    window.AppState.agentVoice = sel.value;
    $('#voiceSelected').textContent = sel.value;
    toast('Voice ' + sel.value + ' selected');
  });

  const previewBtn = $('#previewVoice');
  previewBtn.addEventListener('click', async () => {
    const voice = sel.value;
    const lang = $('#customerLang').value || 'en';   // preview in the customer's language
    previewBtn.disabled = true;
    const orig = previewBtn.innerHTML;
    previewBtn.textContent = 'Synthesising…';
    try {
      await TTS.speak(previewText(lang), { lang, voice });
    } catch (e) {
      toast(e.message, 'err');
    } finally {
      previewBtn.innerHTML = orig;
      previewBtn.disabled = false;
    }
  });
}

/* ============================================================
   Mic capture + VU meter. One recorder at a time (per side).
   ============================================================ */
const Recorder = {
  active: null,          // { side, stream, ctx, raf, recorder, chunks }

  vuBars(vuEl) {
    if (vuEl.childElementCount) return;
    for (let i = 0; i < 5; i++) vuEl.appendChild(document.createElement('span'));
  },

  async start(side, btn) {
    // stop any other side first
    if (this.active) this.stop(this.active.side);

    const panel = side === 'support' ? $('#supportPanel') : $('#customerPanel');
    const vuEl  = side === 'support' ? $('#supportVu')    : $('#customerVu');
    const clip  = side === 'support' ? $('#supportClip')  : $('#customerClip');
    this.vuBars(vuEl);

    let stream;
    try {
      stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    } catch (err) {
      toast('Microphone unavailable — run via server.py over http://localhost', 'err');
      return;
    }

    // Web Audio analyser for the VU meter
    const ctx = new (window.AudioContext || window.webkitAudioContext)();
    const src = ctx.createMediaStreamSource(stream);
    const analyser = ctx.createAnalyser();
    analyser.fftSize = 256;
    src.connect(analyser);
    const data = new Uint8Array(analyser.frequencyBinCount);
    const bars = [...vuEl.children];

    // MediaRecorder captures the clip → handed to the STT→LLM→TTS pipeline
    let recorder = null;
    const chunks = [];
    const session = { side, stream, ctx, raf: 0, recorder: null, chunks, startedAt: Date.now() };
    try {
      recorder = new MediaRecorder(stream);
      recorder.ondataavailable = e => { if (e.data.size) chunks.push(e.data); };
      recorder.onstop = () => {
        const blob = new Blob(chunks, { type: recorder.mimeType || 'audio/webm' });
        if (session.onclip) session.onclip(blob);
      };
      recorder.start();
    } catch (_) { /* capture optional */ }
    session.recorder = recorder;

    // this.active set after the session exists so the loop below halts cleanly.
    this.active = session;

    const tick = () => {
      if (this.active !== session) return;   // stopped or replaced → halt loop
      analyser.getByteFrequencyData(data);
      const band = Math.floor(data.length / bars.length);
      bars.forEach((bar, i) => {
        let sum = 0;
        for (let j = 0; j < band; j++) sum += data[i * band + j];
        const level = (sum / band) / 255;              // 0..1
        bar.style.height = (6 + level * 20).toFixed(1) + 'px';
      });
      session.raf = requestAnimationFrame(tick);
    };
    tick();

    panel.classList.add('is-recording');
    btn.classList.add('is-recording');
    btn.querySelector('.talk-label').textContent = 'Tap to Stop';
    clip.textContent = 'Recording…';
  },

  stop(side) {
    const a = this.active;
    if (!a || a.side !== side) return;

    const secs = ((Date.now() - a.startedAt) / 1000).toFixed(1);
    const panel = side === 'support' ? $('#supportPanel') : $('#customerPanel');
    const vuEl  = side === 'support' ? $('#supportVu')    : $('#customerVu');
    const clip  = side === 'support' ? $('#supportClip')  : $('#customerClip');
    const btn   = panel.querySelector('.talk-btn');

    // On the customer side, feed the captured clip into the pipeline.
    if (side === 'customer' && a.recorder) {
      a.onclip = (blob) => {
        clip.innerHTML = `Captured <b>${secs}s</b> · processing…`;
        Pipeline.fromCustomer(blob);
      };
    } else {
      clip.innerHTML = `Captured <b>${secs}s</b>`;
    }

    cancelAnimationFrame(a.raf);
    if (a.recorder && a.recorder.state !== 'inactive') a.recorder.stop();
    a.stream.getTracks().forEach(t => t.stop());
    a.ctx.close().catch(() => {});

    [...vuEl.children].forEach(b => (b.style.height = '6px'));
    panel.classList.remove('is-recording');
    btn.classList.remove('is-recording');
    btn.querySelector('.talk-label').textContent = 'Press to Speak';

    this.active = null;
  },

  toggle(side, btn) {
    if (this.active && this.active.side === side) this.stop(side);
    else this.start(side, btn);
  }
};

function initTalkButtons() {
  document.querySelectorAll('.talk-btn').forEach(btn => {
    btn.addEventListener('click', () => Recorder.toggle(btn.dataset.side, btn));
  });

  // Upload buttons open the file picker (Phase 1: just acknowledges the file)
  let pendingSide = null;
  const picker = $('#filePicker');
  document.querySelectorAll('.upload-btn').forEach(btn => {
    btn.addEventListener('click', () => { pendingSide = btn.dataset.side; picker.click(); });
  });
  picker.addEventListener('change', () => {
    const f = picker.files[0];
    if (!f) return;
    const clip = pendingSide === 'support' ? $('#supportClip') : $('#customerClip');
    const kb = (f.size / 1024).toFixed(0);
    if (pendingSide === 'customer') {
      clip.innerHTML = `Loaded <b>${f.name}</b> (${kb} KB) · processing…`;
      Pipeline.fromCustomer(f);
    } else {
      clip.innerHTML = `Loaded <b>${f.name}</b> (${kb} KB)`;
    }
    picker.value = '';
  });
}

/* ---------- boot ---------- */
(async function init() {
  const cfg = await Config.load();
  applyBranding(cfg);

  fillSelect($('#customerLang'), LANGUAGES, l => l.code, l => l.name, 'ar');
  fillSelect($('#supportLang'),  LANGUAGES, l => l.code, l => l.name, 'en');

  initModeToggle();
  initVoicePicker();
  initTalkButtons();

  refreshStatus();
  setInterval(refreshStatus, 5000);
})();
