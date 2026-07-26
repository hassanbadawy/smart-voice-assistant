/* ============================================================
   langs.js — Supertonic 3 language + voice catalog.
   31 languages (verified against the Supertonic 3 model card)
   plus `na` language-agnostic. Voices are the open-weight preset
   set; edit if your Supertonic build exposes a different roster.
   ============================================================ */

// Zain / contact-centre relevant languages first, then alphabetical.
const SUPERTONIC_LANGS = [
  { code: 'en', name: 'English' },
  { code: 'ar', name: 'Arabic' },
  { code: 'hi', name: 'Hindi' },
  { code: 'id', name: 'Indonesian' },
  { code: 'fr', name: 'French' },
  { code: 'es', name: 'Spanish' },
  { code: 'tr', name: 'Turkish' },
  { code: 'de', name: 'German' },
  { code: 'it', name: 'Italian' },
  { code: 'pt', name: 'Portuguese' },
  { code: 'nl', name: 'Dutch' },
  { code: 'ru', name: 'Russian' },
  { code: 'uk', name: 'Ukrainian' },
  { code: 'pl', name: 'Polish' },
  { code: 'cs', name: 'Czech' },
  { code: 'sk', name: 'Slovak' },
  { code: 'sl', name: 'Slovenian' },
  { code: 'hr', name: 'Croatian' },
  { code: 'bg', name: 'Bulgarian' },
  { code: 'ro', name: 'Romanian' },
  { code: 'hu', name: 'Hungarian' },
  { code: 'el', name: 'Greek' },
  { code: 'sv', name: 'Swedish' },
  { code: 'da', name: 'Danish' },
  { code: 'fi', name: 'Finnish' },
  { code: 'et', name: 'Estonian' },
  { code: 'lv', name: 'Latvian' },
  { code: 'lt', name: 'Lithuanian' },
  { code: 'vi', name: 'Vietnamese' },
  { code: 'ja', name: 'Japanese' },
  { code: 'ko', name: 'Korean' },
  { code: 'na', name: 'Auto (language-agnostic)' }
];

// Open-weight preset voices. Custom styles can be built with Supertonic Voice Builder.
const SUPERTONIC_VOICES = [
  { id: 'F3', label: 'F3 — Female · 3' },
  { id: 'F4', label: 'F4 — Female · 4' },
  { id: 'F5', label: 'F5 — Female · 5' },
  { id: 'M1', label: 'M1 — Male · 1' },
  { id: 'M3', label: 'M3 — Male · 3' },
  { id: 'M4', label: 'M4 — Male · 4' },
  { id: 'M5', label: 'M5 — Male · 5' }
];

// Short, hand-verified preview lines. Languages without a curated line
// fall back to English (still a valid preview of the voice timbre).
const PREVIEW_SAMPLES = {
  en: 'Hello, this is a preview of this voice.',
  ar: 'مرحبًا، هذه معاينة لهذا الصوت.',
  hi: 'नमस्ते, यह इस आवाज़ का पूर्वावलोकन है।',
  id: 'Halo, ini adalah pratinjau suara ini.',
  fr: 'Bonjour, ceci est un aperçu de cette voix.',
  es: 'Hola, esta es una vista previa de esta voz.',
  tr: 'Merhaba, bu sesin bir önizlemesidir.',
  de: 'Hallo, dies ist eine Vorschau dieser Stimme.',
  it: 'Ciao, questa è un’anteprima di questa voce.',
  pt: 'Olá, esta é uma prévia desta voz.',
  nl: 'Hallo, dit is een voorbeeld van deze stem.',
  ru: 'Здравствуйте, это предпросмотр этого голоса.',
  ja: 'こんにちは、これはこの声のプレビューです。',
  ko: '안녕하세요, 이 목소리의 미리듣기입니다.'
};

function previewText(code) {
  return PREVIEW_SAMPLES[code] || PREVIEW_SAMPLES.en;
}

if (typeof window !== 'undefined') {
  window.SUPERTONIC_LANGS = SUPERTONIC_LANGS;
  window.SUPERTONIC_VOICES = SUPERTONIC_VOICES;
  window.previewText = previewText;
}
