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
