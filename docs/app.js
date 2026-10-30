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
      home: 'Ana: yeni şarkı kartı — sözler, tek tıkla ses çıkışı — yanında hava durumu ve sıradaki toplantın.',
      notifications: 'Bildirimler: gelen her şey tek listede, uygulamaya göre filtrelenir.',
      calendar: 'Takvim: bu hafta ve gerçek etkinliklerin; video görüşmelerine tek tıkla katıl.',
      timer: 'Zamanlayıcı: kadranı çevir ya da −/+ ile istediğin süre; sağda bugünkü odağın.',
      shelf: 'Dosya Rafı: sürükle bırak; küçük resimler, filtreler ve AirDrop.',
      clipboard: 'Pano: son kopyaların; bağlantılar tek tıkla açılır.'
    },
    notchLabel: 'islo. çentiği — açmak için tıklayın'
  },
  en: {
    captions: {
      home: 'Home: the new song card — lyrics, one-click audio output — with the weather and your next meeting beside it.',
      notifications: 'Notifications: everything that arrived, filtered by app.',
      calendar: 'Calendar: this week and your real events; join video calls in one click.',
      timer: 'Timer: turn the dial or use −/+ for any length; today’s focus on the right.',
      shelf: 'File Shelf: drag and drop, with thumbnails, filters, and AirDrop.',
      clipboard: 'Clipboard: your recent copies; links open in one click.'
    },
    notchLabel: 'The islo. notch — click to open'
  }
};

/* Invented lines for the made-up track on this page. */
const lyricLines = {
  tr: ['Şehrin ışıkları camda', 'Bir tren geçer gece yarısı', 'Raylar adını fısıldar', 'Sabaha kadar yol bizim', '♪'],
  en: ['City lights on the window', 'A train rolls past midnight', 'The rails whisper your name', 'The road is ours till morning', '♪']
};

const t = (tr, en) => (language === 'tr' ? tr : en);
const pct = (value) => (language === 'tr' ? `%${value}` : `${value}%`);

function minutesText(minutes) {
  const hours = Math.floor(minutes / 60);
  const rest = minutes % 60;
  if (!hours) return t(`${minutes} dk`, `${minutes} min`);
  if (!rest) return t(`${hours} sa`, `${hours} h`);
  return t(`${hours} sa ${rest} dk`, `${hours} h ${rest} min`);
}

function setLanguage(next) {
  language = next === 'en' ? 'en' : 'tr';
  document.documentElement.lang = language;

  $$('[data-tr]').forEach((el) => { el.textContent = el.dataset[language]; });
  $$('[data-tr-html]').forEach((el) => { el.innerHTML = el.dataset[`${language}Html`]; });
  $$('[data-tr-aria]').forEach((el) => { el.setAttribute('aria-label', el.dataset[`${language}Aria`]); });
  $$('.js-pct').forEach((el) => { el.textContent = pct(el.dataset.v); });
  $$('[data-language]').forEach((button) => {
    button.setAttribute('aria-pressed', String(button.dataset.language === language));
  });

  try { localStorage.setItem('islo-language', language); } catch { /* private mode */ }
  refreshDates();
  updateCaption();
  updateThemeName();
  renderTimer();
  renderLyric(false);
}

$$('[data-language]').forEach((button) => {
  button.addEventListener('click', () => setLanguage(button.dataset.language));
});

/* ---------------------------------------------------------- Date & time */

function locale() { return language === 'tr' ? 'tr-TR' : 'en-US'; }
function clock(date) { return new Intl.DateTimeFormat(locale(), { hour: '2-digit', minute: '2-digit' }).format(date); }
function minutesFromNow(minutes) {
  const date = new Date(Date.now() + minutes * 60000);
  date.setSeconds(0, 0);
  return date;
}
function todayAt(hours, minutes) {
  const date = new Date();
  date.setHours(hours, minutes, 0, 0);
  return date;
}

function refreshDates() {
  const now = new Date();
  const fmt = (options) => new Intl.DateTimeFormat(locale(), options).format(now);

  const time = clock(now);
  $$('.js-time, .js-clock').forEach((el) => { el.textContent = time; });
  $$('.js-weekday').forEach((el) => { el.textContent = fmt({ weekday: 'long' }).toLocaleUpperCase(locale()); });
  $$('.js-date').forEach((el) => { el.textContent = fmt({ day: 'numeric', month: 'short' }); });
  $$('.js-day').forEach((el) => { el.textContent = fmt({ day: 'numeric' }); });
  $$('.js-monthyear').forEach((el) => { el.textContent = fmt({ month: 'long', year: 'numeric' }); });
  $$('.js-longdate').forEach((el) => { el.textContent = fmt({ day: 'numeric', month: 'long', year: 'numeric' }); });
  $$('.js-year').forEach((el) => { el.textContent = String(now.getFullYear()); });

  // Events keep a fixed distance from "now", like a real calendar would.
  const soon = clock(minutesFromNow(12));
  const meeting = clock(minutesFromNow(5));
  $$('.js-ev-soon').forEach((el) => { el.textContent = t(`12 dk sonra · ${soon}`, `In 12 min · ${soon}`); });
  $$('.js-meet-time').forEach((el) => { el.textContent = t(`5 dk sonra · ${meeting}`, `In 5 min · ${meeting}`); });
  $$('.js-ev-later').forEach((el) => { el.textContent = `${clock(todayAt(19, 30))} – ${clock(todayAt(21, 0))}`; });

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

setInterval(() => { refreshDates(); renderTimer(); }, 20000);

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
  if (saved && accents.some((a) => a.id === saved.accent) && tones.some((tone) => tone.id === saved.tone)) theme = saved;
} catch { /* ignore */ }

function hexToRgb(hex) {
  const value = parseInt(hex.slice(1), 16);
  return `${(value >> 16) & 255}, ${(value >> 8) & 255}, ${value & 255}`;
}

function applyTheme(next, { announce = false } = {}) {
  theme = { ...theme, ...next };
  const accent = accents.find((a) => a.id === theme.accent);
  const tone = tones.find((item) => item.id === theme.tone);
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
  const tone = tones.find((item) => item.id === theme.tone);
  $$('.js-theme-name').forEach((el) => { el.textContent = `${accent[language]} · ${tone[language]}`; });
  $$('.swatch').forEach((el) => {
    const item = accents.find((a) => a.id === el.dataset.accent);
    el.setAttribute('aria-label', item[language]);
    el.title = item[language];
  });
  $$('.tone').forEach((el) => {
    const item = tones.find((tone) => tone.id === el.dataset.tone);
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

/* The hero's story: a day with islo., one moment after another. */
const story = [
  ['idle', 1000],
  ['music', 2400],
  ['volume', 2200],
  ['countdown', 2800],
  ['timesup', 2600],
  ['music', 1400],
  ['meeting', 3600],
  ['charging', 2600],
  ['airpods', 3000],
  ['privacy', 2600],
  ['notification', 3600],
  ['music', 2000]
];

const flashDurations = { notification: 4200, meeting: 4200, airpods: 3600, timesup: 3000 };
const sequences = { devices: [['charging', 2600], ['airpods', 3200]] };

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

function flashSequence(steps) {
  if (isOpen || !steps.length) return;
  stopStory();
  clearTimeout(flashTimer);
  const [[state, duration], ...rest] = steps;
  setState(state);
  flashTimer = setTimeout(() => {
    flashTimer = null;
    if (rest.length) flashSequence(rest);
    else showBase();
  }, duration);
}

function flashNotch(state, duration = flashDurations[state] || 3200) {
  flashSequence(sequences[state] || [[state, duration]]);
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

/* ⌥Space toggles the page's notch, like the app's shortcut. */
document.addEventListener('keydown', (event) => {
  if (event.altKey && event.code === 'Space' && !event.metaKey && !event.ctrlKey) {
    event.preventDefault();
    isOpen ? closeNotch() : openNotch();
  }
});

const playButton = $('.nd-play', notch);
playButton.addEventListener('click', (event) => {
  event.stopPropagation();
  const paused = playButton.classList.toggle('is-paused');
  $('use', playButton).setAttribute('href', paused ? '#i-play' : '#i-pause');
  $$('.wave').forEach((wave) => wave.classList.toggle('paused', paused));
});

$$('[data-play]').forEach((button) => {
  button.addEventListener('click', () => {
    const state = button.dataset.play;
    if (state === 'story') { baseMode = 'story'; isOpen = false; playStory(0); return; }
    flashNotch(state);
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
    flashNotch(entry.target.dataset.notch);
  });
}, { threshold: 0.85 });
$$('.moment[data-notch]').forEach((card) => momentObserver.observe(card));

/* The closed notch's countdown wings tick for real. */
const countdownTime = $('.js-cd-time');
const countdownRing = $('.js-cd-ring');
const countdownLength = 2 * Math.PI * 9;
const countdownTotal = 25 * 60;
let countdownLeft = 24 * 60 + 12;

function renderCountdown() {
  const minutes = String(Math.floor(countdownLeft / 60)).padStart(2, '0');
  const seconds = String(countdownLeft % 60).padStart(2, '0');
  countdownTime.textContent = `${minutes}:${seconds}`;
  countdownRing.style.strokeDashoffset = String(countdownLength * (1 - countdownLeft / countdownTotal));
}
if (!reduceMotion) {
  setInterval(() => {
    countdownLeft = countdownLeft > 0 ? countdownLeft - 1 : countdownTotal;
    renderCountdown();
  }, 1000);
}

/* ------------------------------------------------------------- Showcase */

const dash = $('#dash');
const dashWrap = $('#dashWrap');
const screen = $('.device-screen');
const tabs = $$('.d-tab');
const tabOrder = tabs.map((tab) => tab.dataset.tab);
let autoTab = !reduceMotion;
let tabTimer = null;
let lyricsTourTimer = null;

function stopTour() {
  autoTab = false;
  clearTimeout(tabTimer);
  clearTimeout(lyricsTourTimer);
}

function selectTab(tab) {
  dash.dataset.tab = tab;
  tabs.forEach((button) => button.setAttribute('aria-selected', String(button.dataset.tab === tab)));
  updateCaption();
  setOutputs(false);
  setLyrics(false);
  scheduleLyricsTour();
}

/* On the tour, Home turns its lyrics on halfway through. */
function scheduleLyricsTour() {
  clearTimeout(lyricsTourTimer);
  if (!autoTab || dash.dataset.tab !== 'home') return;
  lyricsTourTimer = setTimeout(() => {
    if (autoTab && dash.dataset.tab === 'home') setLyrics(true);
  }, 2600);
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
  }, 5600);
}

tabs.forEach((tab) => {
  tab.addEventListener('click', () => {
    stopTour();
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
    if (entry.isIntersecting) {
      scheduleNextTab();
      if (!mediaCard.classList.contains('show-lyrics')) scheduleLyricsTour();
    } else {
      clearTimeout(tabTimer);
      clearTimeout(lyricsTourTimer);
    }
  });
}, { threshold: 0.4 });
deviceObserver.observe($('#device'));

/* Home: the song plays on, lyrics scroll, and the output can change. */
const mediaCard = $('#mediaCard');
const lyricsToggle = $('.js-lyrics-toggle');
const lyricsBox = $('.js-lyrics');
const songLength = 179;
let songTime = 69;
let lyricIndex = 0;
let lyricTimer = null;

function formatSongTime(seconds) {
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`;
}

function renderSong() {
  $('.js-song-progress').style.setProperty('--p', (songTime / songLength).toFixed(4));
  $('.js-song-elapsed').textContent = formatSongTime(songTime);
  $('.js-song-left').textContent = `-${formatSongTime(songLength - songTime)}`;
}
if (!reduceMotion) {
  setInterval(() => {
    songTime = songTime >= songLength ? 0 : songTime + 1;
    renderSong();
  }, 1000);
}

function renderLyric(animate) {
  const lines = lyricLines[language];
  $('.js-lyric-now').textContent = lines[lyricIndex % lines.length];
  $('.js-lyric-next').textContent = lines[(lyricIndex + 1) % lines.length];
  if (animate) {
    lyricsBox.classList.remove('swap');
    void lyricsBox.offsetWidth;
    lyricsBox.classList.add('swap');
  }
}

function setLyrics(on) {
  mediaCard.classList.toggle('show-lyrics', on);
  lyricsToggle.setAttribute('aria-pressed', String(on));
  clearInterval(lyricTimer);
  if (!on) return;
  renderLyric(false);
  if (!reduceMotion) {
    lyricTimer = setInterval(() => {
      lyricIndex += 1;
      renderLyric(true);
    }, 2600);
  }
}

lyricsToggle.addEventListener('click', () => {
  stopTour();
  setLyrics(!mediaCard.classList.contains('show-lyrics'));
});

function setOutputs(on) {
  mediaCard.classList.toggle('show-outputs', on);
}
$('.js-output-toggle').addEventListener('click', () => { stopTour(); setOutputs(true); });
$('.js-output-close').addEventListener('click', () => setOutputs(false));
$$('.out-chip').forEach((chip) => {
  chip.addEventListener('click', () => {
    $$('.out-chip').forEach((other) => other.classList.toggle('on', other === chip));
    $('.js-output-icon').setAttribute('href', `#i-${chip.dataset.out}`);
    setTimeout(() => setOutputs(false), 350);
  });
});

/* Timer: a working Pomodoro and a kitchen-timer dial. */
const timerCard = $('#timerCard');
const dial = $('.js-dial');
const dialArc = $('.js-dial-arc');
const dialHead = $('.js-dial-head');
const timerToggle = $('.js-timer-toggle');
const arcLength = 2 * Math.PI * 55;
const ranges = { minutes: [1, 180], focus: [5, 90], brk: [1, 30] };
const timer = {
  mode: 'pomodoro',
  minutes: 10,
  focus: 25,
  brk: 5,
  isBreak: false,
  remaining: 25 * 60,
  running: false,
  focusDone: 50,
  sessions: 2
};
let timerInterval = null;

function buildTicks() {
  const group = $('.js-ticks');
  const ns = 'http://www.w3.org/2000/svg';
  for (let i = 0; i < 60; i += 1) {
    const major = i % 5 === 0;
    const angle = (i / 60) * 2 * Math.PI;
    const outer = 69;
    const inner = outer - (major ? 5 : 2.5);
    const line = document.createElementNS(ns, 'line');
    line.setAttribute('x1', (70 + outer * Math.sin(angle)).toFixed(2));
    line.setAttribute('y1', (70 - outer * Math.cos(angle)).toFixed(2));
    line.setAttribute('x2', (70 + inner * Math.sin(angle)).toFixed(2));
    line.setAttribute('y2', (70 - inner * Math.cos(angle)).toFixed(2));
    if (major) line.classList.add('major');
    group.append(line);
  }
}

function totalSeconds() {
  if (timer.mode === 'timer') return timer.minutes * 60;
  return (timer.isBreak ? timer.brk : timer.focus) * 60;
}

/* Timer mode: one turn is an hour. Pomodoro: what's left of the phase. */
function dialFraction() {
  if (timer.mode === 'timer') return Math.min(timer.remaining / 3600, 1);
  return timer.remaining / totalSeconds();
}

/* Single minutes up to 10, then fives — like the app. */
function stepped(value, up, [low, high]) {
  const next = up
    ? (value < 10 ? value + 1 : (Math.floor(value / 5) + 1) * 5)
    : (value <= 10 ? value - 1 : Math.floor((value - 1) / 5) * 5);
  return Math.min(Math.max(next, low), high);
}

function formatClock(seconds) {
  const hours = Math.floor(seconds / 3600);
  const minutes = String(Math.floor(seconds / 60) % 60).padStart(2, '0');
  const rest = String(seconds % 60).padStart(2, '0');
  return hours ? `${hours}:${minutes}:${rest}` : `${minutes}:${rest}`;
}

function focusTotalText(minutes) {
  return minutes < 60 ? t(`${minutes} dk`, `${minutes} min`) : minutesText(minutes);
}

function renderTimer() {
  if (!timerCard) return;
  timerCard.dataset.mode = timer.mode;
  timerCard.classList.toggle('running', timer.running);

  $('.js-timer').textContent = formatClock(timer.remaining);
  const fraction = Math.max(dialFraction(), 0);
  dialArc.style.strokeDasharray = String(arcLength);
  dialArc.style.strokeDashoffset = String(arcLength * (1 - Math.max(fraction, 0.002)));
  const angle = fraction * 2 * Math.PI;
  dialHead.setAttribute('cx', (70 + 55 * Math.sin(angle)).toFixed(2));
  dialHead.setAttribute('cy', (70 - 55 * Math.cos(angle)).toFixed(2));
  dialHead.style.opacity = fraction > 0.004 ? '1' : '0';

  $('.js-phase').textContent = timer.mode === 'timer'
    ? t('Zamanlayıcı', 'Timer')
    : (timer.isBreak ? t('Mola', 'Break') : t('Odak', 'Focus'));
  $$('.js-seg button').forEach((button) => button.classList.toggle('on', button.dataset.mode === timer.mode));

  $('.js-focus-value').textContent = minutesText(timer.focus);
  $('.js-break-value').textContent = minutesText(timer.brk);
  $('.js-minutes-value').textContent = minutesText(timer.minutes);
  $$('[data-step]').forEach((button) => {
    const [key, direction] = button.dataset.step.split(':');
    const [low, high] = ranges[key];
    button.disabled = timer.running || (direction === '-' ? timer[key] <= low : timer[key] >= high);
  });
  $$('.js-presets button').forEach((button) => {
    button.classList.toggle('on', Number(button.dataset.min) === timer.minutes);
  });

  $('use', timerToggle).setAttribute('href', timer.running ? '#i-pause' : '#i-play');
  timerToggle.setAttribute('aria-label', timer.running ? t('Duraklat', 'Pause') : t('Başlat', 'Start'));

  $('.js-focus-total').textContent = focusTotalText(timer.focusDone);
  $$('.js-session-bars i').forEach((bar, index) => bar.classList.toggle('on', index < timer.sessions % 4));
  $('.js-sessions').textContent = t(
    `${timer.sessions} seans tamamlandı`,
    `${timer.sessions} ${timer.sessions === 1 ? 'session' : 'sessions'} done`
  );
  $('.js-end-label').textContent = timer.running ? t('Bitiş', 'Ends') : t('Şimdi başlarsan', 'If you start now');
  $('.js-end-time').textContent = clock(new Date(Date.now() + timer.remaining * 1000));
  $('.js-next-row').hidden = timer.mode !== 'pomodoro';
  $('.js-next-text').textContent = timer.isBreak
    ? t(`${timer.focus} dk odak`, `${timer.focus} min focus`)
    : t(`${timer.brk} dk mola`, `${timer.brk} min break`);
  $('use', $('.js-next-icon')).setAttribute('href', timer.isBreak ? '#i-timer' : '#i-cup');
}

function setDuration(key, value) {
  timer[key] = value;
  const isCurrent = timer.mode === 'timer' ? key === 'minutes' : key === (timer.isBreak ? 'brk' : 'focus');
  if (isCurrent && !timer.running) timer.remaining = totalSeconds();
  renderTimer();
}

function stopCountdown() {
  clearInterval(timerInterval);
  timerInterval = null;
  timer.running = false;
}

function tickTimer() {
  timer.remaining -= 1;
  if (timer.remaining > 0) { renderTimer(); return; }
  stopCountdown();
  if (timer.mode === 'timer' || !timer.isBreak) {
    timer.focusDone += Math.round(totalSeconds() / 60);
    if (timer.mode === 'pomodoro') timer.sessions += 1;
  }
  if (timer.mode === 'pomodoro') timer.isBreak = !timer.isBreak;
  timer.remaining = totalSeconds();
  renderTimer();
  flashNotch('timesup');
}

timerToggle.addEventListener('click', () => {
  stopTour();
  if (timer.running) {
    stopCountdown();
  } else {
    if (timer.remaining <= 0) timer.remaining = totalSeconds();
    timer.running = true;
    timerInterval = setInterval(tickTimer, 1000);
  }
  renderTimer();
});

$('.js-timer-reset').addEventListener('click', () => {
  stopTour();
  stopCountdown();
  timer.isBreak = false;
  timer.remaining = totalSeconds();
  renderTimer();
});

$('.js-timer-skip').addEventListener('click', () => {
  stopTour();
  if (timer.mode !== 'pomodoro') return;
  stopCountdown();
  timer.isBreak = !timer.isBreak;
  timer.remaining = totalSeconds();
  renderTimer();
});

$$('.js-seg button').forEach((button) => {
  button.addEventListener('click', () => {
    stopTour();
    stopCountdown();
    timer.mode = button.dataset.mode;
    timer.isBreak = false;
    timer.remaining = totalSeconds();
    renderTimer();
  });
});

$$('[data-step]').forEach((button) => {
  button.addEventListener('click', () => {
    stopTour();
    const [key, direction] = button.dataset.step.split(':');
    setDuration(key, stepped(timer[key], direction === '+', ranges[key]));
  });
});

$$('.js-presets button').forEach((button) => {
  button.addEventListener('click', () => {
    stopTour();
    setDuration('minutes', Number(button.dataset.min));
  });
});

/* Drag around the dial to set up to an hour. */
let draggingDial = false;
function minutesAt(event) {
  const box = dial.getBoundingClientRect();
  const dx = event.clientX - (box.left + box.width / 2);
  const dy = event.clientY - (box.top + box.height / 2);
  if (Math.hypot(dx, dy) < box.width * 0.22) return null;
  let angle = Math.atan2(dx, -dy);
  if (angle < 0) angle += 2 * Math.PI;
  const minutes = Math.round((angle / (2 * Math.PI)) * 60);
  return minutes === 0 ? 60 : minutes;
}
dial.addEventListener('pointerdown', (event) => {
  if (timer.mode !== 'timer' || timer.running) return;
  stopTour();
  draggingDial = true;
  try { dial.setPointerCapture(event.pointerId); } catch { /* not a live pointer */ }
  const minutes = minutesAt(event);
  if (minutes) setDuration('minutes', minutes);
});
dial.addEventListener('pointermove', (event) => {
  if (!draggingDial) return;
  const minutes = minutesAt(event);
  if (minutes && minutes !== timer.minutes) setDuration('minutes', minutes);
});
['pointerup', 'pointercancel'].forEach((type) => {
  dial.addEventListener(type, () => { draggingDial = false; });
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
buildTicks();
renderSong();
renderCountdown();
selectTab('home');
clearTimeout(lyricsTourTimer);

let initialLanguage = navigator.language.toLowerCase().startsWith('tr') ? 'tr' : 'en';
try { initialLanguage = localStorage.getItem('islo-language') || initialLanguage; } catch { /* ignore */ }
setLanguage(initialLanguage);

fitDash();
playStory(0);
