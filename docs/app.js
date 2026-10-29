const languageButtons = document.querySelectorAll('[data-language]');
const translatable = document.querySelectorAll('[data-tr][data-en]');
const description = document.querySelector('meta[name="description"]');

function setLanguage(language) {
  const selected = language === 'en' ? 'en' : 'tr';
  document.documentElement.lang = selected;

  translatable.forEach((element) => {
    element.textContent = element.dataset[selected];
  });

  languageButtons.forEach((button) => {
    const isActive = button.dataset.language === selected;
    button.classList.toggle('active', isActive);
    button.setAttribute('aria-pressed', String(isActive));
  });

  description.content = selected === 'tr'
    ? 'IslandX, MacBook çentiğiyle bütünleşen zarif Music ve Spotify kontrolleridir.'
    : 'IslandX brings elegant Music and Spotify controls to your MacBook notch.';

  localStorage.setItem('islandx-language', selected);
}

languageButtons.forEach((button) => {
  button.addEventListener('click', () => setLanguage(button.dataset.language));
});

const savedLanguage = localStorage.getItem('islandx-language');
const browserLanguage = navigator.language.toLowerCase().startsWith('tr') ? 'tr' : 'en';
setLanguage(savedLanguage || browserLanguage);

document.querySelector('#year').textContent = new Date().getFullYear();

const observer = new IntersectionObserver((entries) => {
  entries.forEach((entry) => {
    if (entry.isIntersecting) {
      entry.target.classList.add('visible');
      observer.unobserve(entry.target);
    }
  });
}, { threshold: 0.12 });

document.querySelectorAll('.reveal').forEach((element) => observer.observe(element));

const behaviorDemo = document.querySelector('.behavior-demo');
const behaviorButtons = document.querySelectorAll('[data-behavior]');
const behaviorCaption = document.querySelector('.behavior-caption');
const behaviorCopy = {
  hover: {
    tr: 'İmleç çentiğe geldiğinde kontroller yumuşakça açılır.',
    en: 'Controls expand smoothly when the pointer reaches the notch.'
  },
  click: {
    tr: 'Yalnızca siz tıkladığınızda açılır; çalışırken kapalı kalır.',
    en: 'It opens only when you click and stays compact while you work.'
  },
  zone: {
    tr: 'Çentiğin belirlediğiniz orta bölgesine yaklaşmanız yeterlidir.',
    en: 'Simply move into the chosen center zone around the notch.'
  }
};
let behaviorIndex = 0;
let behaviorTimer;

function setBehavior(mode, restart = true) {
  if (!behaviorDemo || !behaviorCopy[mode]) return;
  const selectedLanguage = document.documentElement.lang === 'en' ? 'en' : 'tr';
  behaviorDemo.dataset.demoMode = mode;
  behaviorIndex = ['hover', 'click', 'zone'].indexOf(mode);
  behaviorButtons.forEach((button) => {
    const isActive = button.dataset.behavior === mode;
    button.classList.toggle('active', isActive);
    button.setAttribute('aria-pressed', String(isActive));
  });
  behaviorCaption.textContent = behaviorCopy[mode][selectedLanguage];
  const animatedParts = behaviorDemo.querySelectorAll('.behavior-island, .behavior-details, .behavior-pointer, .behavior-pointer span');
  animatedParts.forEach((part) => { part.style.animationName = 'none'; });
  void behaviorDemo.offsetWidth;
  animatedParts.forEach((part) => { part.style.animationName = ''; });
  if (restart && !window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
    clearInterval(behaviorTimer);
    behaviorTimer = setInterval(() => setBehavior(['hover', 'click', 'zone'][(behaviorIndex + 1) % 3], false), 5400);
  }
}

behaviorButtons.forEach((button) => button.addEventListener('click', () => setBehavior(button.dataset.behavior)));
setBehavior('hover');

languageButtons.forEach((button) => {
  button.addEventListener('click', () => {
    if (behaviorDemo) setBehavior(behaviorDemo.dataset.demoMode, false);
  });
});

const layoutShowcase = document.querySelector('.layout-showcase');
const layoutButtons = document.querySelectorAll('[data-layout-choice]');
let layoutTimer;

function setLayout(layout, restart = true) {
  if (!layoutShowcase || !['music', 'dashboard'].includes(layout)) return;
  layoutShowcase.dataset.layout = layout;
  layoutButtons.forEach((button) => {
    const isActive = button.dataset.layoutChoice === layout;
    button.classList.toggle('active', isActive);
    button.setAttribute('aria-pressed', String(isActive));
  });

  if (restart && !window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
    clearInterval(layoutTimer);
    layoutTimer = setInterval(() => {
      setLayout(layoutShowcase.dataset.layout === 'dashboard' ? 'music' : 'dashboard', false);
    }, 7000);
  }
}

layoutButtons.forEach((button) => {
  button.addEventListener('click', () => setLayout(button.dataset.layoutChoice));
});
setLayout('dashboard');
