/* islo. — website behaviour.
   The page has its own notch that tells the app's story, reacts to the
   section you're reading, opens on hover, and follows the theme you pick. */

const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
const canHover = window.matchMedia('(hover: hover) and (pointer: fine)').matches;

let language = 'tr';

/* ------------------------------------------------------------- Language */

const copy = {
  tr: {
    captions: {
      home: 'Ana: çalan parça, kontroller ve günün özeti tek bakışta.',
      notifications: 'Bildirimler: gelen her şey tek listede, uygulamaya göre filtrelenir.',
      calendar: 'Takvim: bugün, bu hafta ve tek dokunuşla yeni etkinlik.',
      timer: 'Zamanlayıcı: Pomodoro ya da serbest süre, çentiğin kendi tasarımıyla.',
      shelf: 'Dosya Rafı: sürükle bırak; küçük resimler, filtreler ve AirDrop.',
      clipboard: 'Pano: son kopyaların; bağlantılar tek tıkla açılır.'
    },
    notchLabel: 'islo. çentiği — açmak için tıklayın'
  },
  en: {
    captions: {
      home: 'Home: what’s playing, controls, and your day at a glance.',
      notifications: 'Notifications: everything that arrived, filtered by app.',
      calendar: 'Calendar: today, this week, and a new event in one tap.',
      timer: 'Timer: Pomodoro or a free countdown, in the notch’s own design.',
      shelf: 'File Shelf: drag and drop, with thumbnails, filters, and AirDrop.',
      clipboard: 'Clipboard: your recent copies; links open in one click.'
    },
    notchLabel: 'The islo. notch — click to open'
  }
};

function setLanguage(next) {
  language = next === 'en' ? 'en' : 'tr';
  document.documentElement.lang = language;

  $$('[data-tr]').forEach((el) => { el.textContent = el.dataset[language]; });
  $$('[data-tr-html]').forEach((el) => { el.innerHTML = el.dataset[`${language}Html`]; });
  $$('[data-tr-aria]').forEach((el) => { el.setAttribute('aria-label', el.dataset[`${language}Aria`]); });
  $$('[data-language]').forEach((button) => {
    button.setAttribute('aria-pressed', String(button.dataset.language === language));
  });

  try { localStorage.setItem('islo-language', language); } catch { /* private mode */ }
  refreshDates();
  updateCaption();
  updateThemeName();
}

$$('[data-language]').forEach((button) => {
  button.addEventListener('click', () => setLanguage(button.dataset.language));
});

/* ---------------------------------------------------------- Date & time */

function locale() { return language === 'tr' ? 'tr-TR' : 'en-US'; }

function refreshDates() {
  const now = new Date();
  const fmt = (options) => new Intl.DateTimeFormat(locale(), options).format(now);

  const time = fmt({ hour: '2-digit', minute: '2-digit' });
  $$('.js-time, .js-clock').forEach((el) => { el.textContent = time; });
  $$('.js-weekday').forEach((el) => { el.textContent = fmt({ weekday: 'long' }).toLocaleUpperCase(locale()); });
  $$('.js-date').forEach((el) => { el.textContent = fmt({ day: 'numeric', month: 'short' }); });
  $$('.js-day').forEach((el) => { el.textContent = fmt({ day: 'numeric' }); });
  $$('.js-monthyear').forEach((el) => { el.textContent = fmt({ month: 'long', year: 'numeric' }); });
  $$('.js-longdate').forEach((el) => { el.textContent = fmt({ day: 'numeric', month: 'long', year: 'numeric' }); });
  $$('.js-year').forEach((el) => { el.textContent = String(now.getFullYear()); });

  const week = $('.js-week');
  if (week) {
    const monday = new Date(now);
    monday.setDate(now.getDate() - ((now.getDay() + 6) % 7));
    const dayName = new Intl.DateTimeFormat(locale(), { weekday: 'short' });
    week.innerHTML = '';
    for (let i = 0; i < 7; i += 1) {
      const day = new Date(monday);
      day.setDate(monday.getDate() + i);
      const cell = document.createElement('span');
      if (day.toDateString() === now.toDateString()) cell.className = 'today';
      cell.textContent = dayName.format(day).replace('.', '');
      const number = document.createElement('b');
      number.textContent = String(day.getDate());
      cell.append(number);
      week.append(cell);
    }
  }
}

setInterval(refreshDates, 20000);

/* ---------------------------------------------------------------- Theme */

const accents = [
  { id: 'blue', hex: '#458cff', tr: 'Mavi', en: 'Blue' },
  { id: 'purple', hex: '#ad6bff', tr: 'Mor', en: 'Purple' },
  { id: 'pink', hex: '#ff619e', tr: 'Pembe', en: 'Pink' },
  { id: 'red', hex: '#ff544f', tr: 'Kırmızı', en: 'Red' },
  { id: 'orange', hex: '#ff9433', tr: 'Turuncu', en: 'Orange' },
  { id: 'yellow', hex: '#ffcc33', tr: 'Sarı', en: 'Yellow', light: true },
  { id: 'green', hex: '#40d16b', tr: 'Yeşil', en: 'Green' },
  { id: 'mint', hex: '#4de0bf', tr: 'Nane', en: 'Mint', light: true },
  { id: 'teal', hex: '#33bddb', tr: 'Turkuaz', en: 'Teal' },
  { id: 'graphite', hex: '#a8a8a8', tr: 'Grafit', en: 'Graphite', light: true }
];
const tones = [
  { id: 'black', value: 0, tr: 'Saf siyah', en: 'Pure black' },
  { id: 'subtle', value: 0.22, tr: 'Hafif', en: 'Subtle' },
  { id: 'medium', value: 0.4, tr: 'Orta', en: 'Medium' },
  { id: 'vivid', value: 0.62, tr: 'Canlı', en: 'Vivid' }
];

let theme = { accent: 'blue', tone: 'subtle' };
try {
  const saved = JSON.parse(localStorage.getItem('islo-theme') || 'null');
  if (saved && accents.some((a) => a.id === saved.accent) && tones.some((t) => t.id === saved.tone)) theme = saved;
} catch { /* ignore */ }

function hexToRgb(hex) {
  const value = parseInt(hex.slice(1), 16);
  return `${(value >> 16) & 255}, ${(value >> 8) & 255}, ${value & 255}`;
}

function applyTheme(next, { announce = false } = {}) {
  theme = { ...theme, ...next };
  const accent = accents.find((a) => a.id === theme.accent);
  const tone = tones.find((t) => t.id === theme.tone);
  const root = document.documentElement.style;
  root.setProperty('--accent', accent.hex);
  root.setProperty('--accent-rgb', hexToRgb(accent.hex));
  root.setProperty('--tone', String(tone.value));

  $$('.swatch').forEach((el) => el.setAttribute('aria-checked', String(el.dataset.accent === theme.accent)));
  $$('.tone').forEach((el) => el.setAttribute('aria-checked', String(el.dataset.tone === theme.tone)));
  updateThemeName();

  try { localStorage.setItem('islo-theme', JSON.stringify(theme)); } catch { /* ignore */ }
  if (announce) flashNotch('theme', 2400);
}

function updateThemeName() {
  const accent = accents.find((a) => a.id === theme.accent);
  const tone = tones.find((t) => t.id === theme.tone);
  $$('.js-theme-name').forEach((el) => { el.textContent = `${accent[language]} · ${tone[language]}`; });
  $$('.swatch').forEach((el) => {
    const item = accents.find((a) => a.id === el.dataset.accent);
    el.setAttribute('aria-label', item[language]);
    el.title = item[language];
  });
  $$('.tone').forEach((el) => {
    const item = tones.find((t) => t.id === el.dataset.tone);
    $('span', el).textContent = item[language];
  });
}

function buildThemePicker() {
  const swatches = $('#swatches');
  const toneList = $('#tones');
  accents.forEach((accent) => {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = `swatch${accent.light ? ' light' : ''}`;
    button.setAttribute('role', 'radio');
    button.dataset.accent = accent.id;
    button.style.setProperty('--c', accent.hex);
    button.addEventListener('click', () => applyTheme({ accent: accent.id }, { announce: true }));
    swatches.append(button);
  });
  tones.forEach((tone) => {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'tone';
    button.setAttribute('role', 'radio');
    button.dataset.tone = tone.id;
    button.style.setProperty('--o', String(tone.value));
    button.innerHTML = '<i></i><span></span>';
    button.addEventListener('click', () => applyTheme({ tone: tone.id }, { announce: true }));
    toneList.append(button);
  });
}

/* -------------------------------------------------------------- The notch */

const notch = $('#siteNotch');
const volumeLabel = $('.js-vol', notch);
let baseMode = 'story';
let storyTimer = null;
let flashTimer = null;
let closeTimer = null;
let isOpen = false;
let volumeTimer = null;

function setState(state) {
  notch.dataset.state = state;
  if (state === 'volume') animateVolume();
}

function animateVolume() {
  clearInterval(volumeTimer);
  let value = 38;
  volumeLabel.textContent = String(value);
  volumeTimer = setInterval(() => {
    value = Math.min(value + 6, 81);
    volumeLabel.textContent = String(value);
    if (value >= 81) clearInterval(volumeTimer);
  }, 110);
}

const story = [
  ['idle', 1000],
  ['music', 2600],
  ['volume', 2300],
  ['music', 1500],
  ['notification', 3800],
  ['music', 2200]
];

function stopStory() {
  clearTimeout(storyTimer);
  storyTimer = null;
}

function playStory(index = 0) {
  stopStory();
  if (reduceMotion) { setState('music'); return; }
  const [state, duration] = story[index % story.length];
  setState(state);
  storyTimer = setTimeout(() => playStory(index + 1), duration);
}

function showBase() {
  if (isOpen) return;
  if (baseMode === 'story') { playStory(1); return; }
  stopStory();
  setState(baseMode);
}

function flashNotch(state, duration = 3000) {
  if (isOpen) return;
  stopStory();
  clearTimeout(flashTimer);
  setState(state);
  flashTimer = setTimeout(() => { flashTimer = null; showBase(); }, duration);
}

function openNotch() {
  clearTimeout(closeTimer);
  if (isOpen) return;
  isOpen = true;
  stopStory();
  clearTimeout(flashTimer);
  setState('dash');
}

function closeNotch() {
  if (!isOpen) return;
  isOpen = false;
  showBase();
}

if (canHover) {
  notch.addEventListener('mouseenter', openNotch);
  notch.addEventListener('mouseleave', () => {
    clearTimeout(closeTimer);
    closeTimer = setTimeout(closeNotch, 380);
  });
}
notch.addEventListener('click', (event) => {
  if (event.target.closest('.nd-close')) { closeNotch(); event.stopPropagation(); return; }
  if (event.target.closest('.nd-play')) return;
  if (!isOpen) openNotch();
});
notch.addEventListener('keydown', (event) => {
  if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); isOpen ? closeNotch() : openNotch(); }
  if (event.key === 'Escape') closeNotch();
});
document.addEventListener('click', (event) => {
  if (isOpen && !notch.contains(event.target)) closeNotch();
});

const playButton = $('.nd-play', notch);
playButton.addEventListener('click', (event) => {
  event.stopPropagation();
  const waves = $$('.wave');
  const paused = playButton.classList.toggle('is-paused');
  $('use', playButton).setAttribute('href', paused ? '#i-play' : '#i-pause');
  waves.forEach((wave) => wave.classList.toggle('paused', paused));
});

$$('[data-play]').forEach((button) => {
  button.addEventListener('click', () => {
    const state = button.dataset.play;
    if (state === 'story') { baseMode = 'story'; isOpen = false; playStory(0); return; }
    flashNotch(state, state === 'notification' ? 4200 : 3200);
  });
});

/* The notch follows the section you're reading. */
const sectionObserver = new IntersectionObserver((entries) => {
  entries.forEach((entry) => {
    if (!entry.isIntersecting) return;
    const mode = entry.target.dataset.notch;
    if (mode === baseMode) return;
    baseMode = mode;
    if (!flashTimer) showBase();
  });
}, { rootMargin: '-45% 0px -45% 0px' });
$$('section[data-notch]').forEach((section) => sectionObserver.observe(section));

const momentObserver = new IntersectionObserver((entries) => {
  entries.forEach((entry) => {
    if (!entry.isIntersecting) return;
    momentObserver.unobserve(entry.target);
    flashNotch(entry.target.dataset.notch, 3200);
  });
}, { threshold: 0.85 });
$$('.moment[data-notch]').forEach((card) => momentObserver.observe(card));

/* ------------------------------------------------------------- Showcase */

const dash = $('#dash');
const dashWrap = $('#dashWrap');
const screen = $('.device-screen');
const tabs = $$('.d-tab');
const tabOrder = tabs.map((tab) => tab.dataset.tab);
let autoTab = !reduceMotion;
let tabTimer = null;

function selectTab(tab) {
  dash.dataset.tab = tab;
  tabs.forEach((button) => button.setAttribute('aria-selected', String(button.dataset.tab === tab)));
  updateCaption();
}

function updateCaption() {
  const caption = $('.js-tab-caption');
  if (caption && dash) caption.textContent = copy[language].captions[dash.dataset.tab];
}

function scheduleNextTab() {
  clearTimeout(tabTimer);
  if (!autoTab) return;
  tabTimer = setTimeout(() => {
    const next = tabOrder[(tabOrder.indexOf(dash.dataset.tab) + 1) % tabOrder.length];
    selectTab(next);
    scheduleNextTab();
  }, 5200);
}

tabs.forEach((tab) => {
  tab.addEventListener('click', () => {
    autoTab = false;
    clearTimeout(tabTimer);
    selectTab(tab.dataset.tab);
  });
});

function fitDash() {
  const width = screen.clientWidth;
  const scale = Math.min(1.3, (width * 0.76) / 780);
  dashWrap.style.setProperty('--s', scale.toFixed(4));
}
new ResizeObserver(fitDash).observe(screen);

/* Start the tab tour only once the device is on screen. */
const deviceObserver = new IntersectionObserver((entries) => {
  entries.forEach((entry) => {
    if (entry.isIntersecting) scheduleNextTab();
    else clearTimeout(tabTimer);
  });
}, { threshold: 0.4 });
deviceObserver.observe($('#device'));

/* A working Pomodoro in the timer tab. */
const ring = $('.js-ring');
const timerLabel = $('.js-timer');
const timerToggle = $('.js-timer-toggle');
const ringLength = 2 * Math.PI * 52;
const total = 25 * 60;
let remaining = total;
let countdown = null;

function renderTimer() {
  const minutes = String(Math.floor(remaining / 60)).padStart(2, '0');
  const seconds = String(remaining % 60).padStart(2, '0');
  timerLabel.textContent = `${minutes}:${seconds}`;
  const progress = Math.max(1 - remaining / total, 0.004);
  ring.style.strokeDasharray = String(ringLength);
  ring.style.strokeDashoffset = String(ringLength * (1 - progress));
}

timerToggle.addEventListener('click', () => {
  autoTab = false;
  clearTimeout(tabTimer);
  if (countdown) {
    clearInterval(countdown);
    countdown = null;
    $('use', timerToggle).setAttribute('href', '#i-play');
    return;
  }
  $('use', timerToggle).setAttribute('href', '#i-pause');
  countdown = setInterval(() => {
    remaining = remaining > 0 ? remaining - 1 : total;
    renderTimer();
  }, 1000);
});

/* Mini volume HUD in the moments section. */
const miniVolume = $('.js-mini-vol');
if (miniVolume && !reduceMotion) {
  let level = 40;
  setInterval(() => {
    level = level >= 88 ? 40 : level + 6;
    miniVolume.textContent = String(level);
  }, 400);
}

/* --------------------------------------------------------------- Reveal */

const revealObserver = new IntersectionObserver((entries) => {
  entries.forEach((entry) => {
    if (!entry.isIntersecting) return;
    entry.target.classList.add('visible');
    revealObserver.unobserve(entry.target);
  });
}, { threshold: 0.14 });
$$('.reveal').forEach((el) => revealObserver.observe(el));

/* ------------------------------------------------------------------ Go */

buildThemePicker();
applyTheme(theme);
selectTab('home');
renderTimer();

let initialLanguage = navigator.language.toLowerCase().startsWith('tr') ? 'tr' : 'en';
try { initialLanguage = localStorage.getItem('islo-language') || initialLanguage; } catch { /* ignore */ }
setLanguage(initialLanguage);

fitDash();
playStory(0);
