/* ============================================================
   settings.js — edit STT/LLM/TTS + branding, persist to YAML.
   ============================================================ */

const $ = (s, r = document) => r.querySelector(s);

let toastTimer;
function toast(msg, kind = '') {
  const el = $('#toast');
  el.textContent = msg;
  el.className = 'toast show ' + kind;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (el.className = 'toast ' + kind), 2600);
}

let logoDataUri = '';   // '' = use default

function renderLogo() {
  const holder = $('#logoPreview');
  const header = $('#brandLogo');
  holder.innerHTML = '';
  header.innerHTML = '';
  const src = logoDataUri || 'assets/default-logo.svg';
  for (const box of [holder, header]) {
    const img = document.createElement('img');
    img.src = src;
    img.alt = 'logo';
    box.appendChild(img);
  }
}

function fillForm(cfg) {
  const s = cfg.services;
  $('#sttName').value = s.stt.name || '';
  $('#sttEndpoint').value = s.stt.endpoint || '';
  $('#sttToken').value = s.stt.token || '';
  $('#llmName').value = s.llm.name || '';
  $('#llmEndpoint').value = s.llm.endpoint || '';
  $('#llmToken').value = s.llm.token || '';
  $('#ttsName').value = s.tts.name || '';
  $('#ttsEndpoint').value = s.tts.endpoint || '';
  $('#ttsToken').value = s.tts.token || '';
  $('#ttsApi').value = s.tts.api || 'native';
  $('#ttsFormat').value = s.tts.format || 'wav';
  $('#ttsSpeed').value = s.tts.speed || '1.0';

  $('#appTitleInput').value = cfg.branding?.app_title || '';
  $('#themeSelect').value = (window.THEMES || []).includes(cfg.branding?.theme) ? cfg.branding.theme : 'green';
  Config.applyTheme($('#themeSelect').value);          // reflect the saved theme live
  logoDataUri = cfg.branding?.logo || '';
  renderLogo();
}

function readForm() {
  return {
    branding: {
      app_title: $('#appTitleInput').value.trim() || 'Smart Voice Assistant',
      logo: logoDataUri,
      theme: $('#themeSelect').value
    },
    services: {
      stt: { name: $('#sttName').value.trim(), endpoint: $('#sttEndpoint').value.trim(), token: $('#sttToken').value },
      llm: { name: $('#llmName').value.trim(), endpoint: $('#llmEndpoint').value.trim(), token: $('#llmToken').value },
      tts: {
        name: $('#ttsName').value.trim(),
        endpoint: $('#ttsEndpoint').value.trim(),
        token: $('#ttsToken').value,
        api: $('#ttsApi').value,
        format: $('#ttsFormat').value,
        speed: $('#ttsSpeed').value.trim() || '1.0'
      }
    }
  };
}

/* ---------- status pill ---------- */
async function refreshStatus() {
  const pill = $('#statusPill');
  try {
    const res = await fetch('/api/health', { cache: 'no-store' });
    if (res.ok) { pill.classList.add('is-online'); $('#statusText').textContent = 'Connected'; return; }
  } catch (_) {}
  pill.classList.remove('is-online');
  $('#statusText').textContent = 'Disconnected';
}

/* ---------- theme ---------- */
function initTheme() {
  // Live-preview the theme as soon as it's picked (persist on Save).
  $('#themeSelect').addEventListener('change', (e) => Config.applyTheme(e.target.value));
}

/* ---------- logo picking ---------- */
function initLogo() {
  const file = $('#logoFile');
  $('#logoPick').addEventListener('click', () => file.click());
  $('#logoClear').addEventListener('click', () => { logoDataUri = ''; renderLogo(); toast('Logo reset to default'); });
  file.addEventListener('change', () => {
    const f = file.files[0];
    if (!f) return;
    if (f.size > 512 * 1024) { toast('Logo too large — keep it under 512 KB', 'err'); return; }
    const reader = new FileReader();
    reader.onload = () => { logoDataUri = reader.result; renderLogo(); toast('Logo updated — remember to Save'); };
    reader.readAsDataURL(f);
    file.value = '';
  });
}

/* ---------- import / download / save ---------- */
function initActions() {
  $('#saveBtn').addEventListener('click', async () => {
    const cfg = readForm();
    const { mode } = await Config.save(cfg);
    if (mode === 'yaml') toast('Saved to config.yaml', 'ok');
    else toast('No backend — downloaded config.yaml instead', 'ok');
  });

  $('#downloadBtn').addEventListener('click', () => {
    Config.download(readForm());
    toast('config.yaml downloaded', 'ok');
  });

  const importFile = $('#importFile');
  $('#importBtn').addEventListener('click', () => importFile.click());
  importFile.addEventListener('change', () => {
    const f = importFile.files[0];
    if (!f) return;
    const reader = new FileReader();
    reader.onload = () => {
      try {
        const cfg = Config.parseYaml(String(reader.result));
        fillForm(cfg);
        toast('Imported — review, then Save', 'ok');
      } catch (err) {
        toast('Could not parse that YAML file', 'err');
      }
    };
    reader.readAsText(f);
    importFile.value = '';
  });
}

/* ---------- boot ---------- */
(async function init() {
  const cfg = await Config.load();
  fillForm(cfg);
  initTheme();
  initLogo();
  initActions();
  refreshStatus();
  setInterval(refreshStatus, 5000);
})();
