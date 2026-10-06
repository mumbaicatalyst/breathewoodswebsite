const header = document.querySelector('#siteHeader');
const dialog = document.querySelector('#bookingDialog');
const menuDialog = document.querySelector('#menuDialog');

function tightenMenu(dialogElement) {
  dialogElement.setAttribute('aria-label', 'Site menu');
  dialogElement.removeAttribute('aria-labelledby');
  dialogElement.querySelector('h2')?.remove();
  const oldLinks = dialogElement.querySelector('.menu-social');
  if (oldLinks) oldLinks.outerHTML = '<div class="menu-contact-links" aria-label="Contact Breathe Woods"><a href="https://wa.me/919967786444" aria-label="Message Breathe Woods on WhatsApp"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M20.5 11.6a8.3 8.3 0 0 1-12.25 7.3L4 20l1.15-4.05A8.3 8.3 0 1 1 20.5 11.6Z"/><path d="M9 8.2c.2-.4.4-.4.6-.4h.4c.2 0 .3.1.4.3l.6 1.5c.1.2.1.3 0 .5l-.3.4c-.1.2-.1.3 0 .5.3.6.9 1.2 1.6 1.6.2.1.3.1.5 0l.5-.6c.1-.2.3-.2.5-.1l1.5.7c.2.1.3.2.3.4 0 .5-.2 1-.6 1.3-.5.3-1.3.3-2.4-.2-1-.5-2.1-1.3-3.1-2.3-1-1-1.7-2.1-2.1-3.1-.3-.9-.1-1.7.2-2.2Z"/></svg></a><a href="tel:+919967786444" aria-label="Call Breathe Woods"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M7.1 3.7 9.5 6c.32.32.38.82.15 1.2L8.5 9.2a14.2 14.2 0 0 0 6.3 6.3l2-1.15c.39-.23.88-.17 1.2.15l2.3 2.4c.34.35.37.9.06 1.28l-1.25 1.48c-.37.44-.96.64-1.52.5C10.1 18.2 5.8 13.9 3.84 6.41c-.15-.56.06-1.15.5-1.52l1.48-1.25c.38-.3.93-.28 1.28.06Z"/></svg></a></div>';
}
tightenMenu(menuDialog);

const pageLinks = document.createElement('nav');
pageLinks.className = 'page-next-links';
pageLinks.setAttribute('aria-label', 'Continue exploring Breathe Woods');
pageLinks.innerHTML = '<a href="index.html">Home</a><a href="property.html">Property</a><a href="dining.html">Dining</a><a href="explore.html">Explore</a><a href="information.html">Information</a><a href="contact.html">Contact</a>';
document.querySelector('main')?.append(pageLinks);

window.addEventListener('scroll', () => header.classList.toggle('scrolled', window.scrollY > 40), { passive: true });

function bookingUrl(values = {}) {
  const localBooking = ['localhost', '127.0.0.1'].includes(window.location.hostname);
  const url = new URL(localBooking ? 'http://127.0.0.1:5173/' : '/book/', window.location.origin);
  url.searchParams.set('returnTo', window.location.href);
  Object.entries(values).forEach(([key, value]) => { if (value) url.searchParams.set(key, String(value)); });
  return url.toString();
}
function openBooking(values = {}) { window.location.assign(bookingUrl(values)); }

document.querySelectorAll('[data-book]').forEach((button) => {
  button.addEventListener('click', () => {
    const label = button.textContent || '';
    const stay = button.dataset.bookStay || (label.includes('Zen Villa') ? 'zen-villa' : label.includes('Bougan') ? 'bougan-villa' : '');
    openBooking({ stay });
  });
});
document.querySelector('#openMenu').addEventListener('click', () => menuDialog.showModal());
document.querySelector('#closeMenu').addEventListener('click', () => menuDialog.close());
menuDialog.querySelectorAll('a').forEach((link) => link.addEventListener('click', () => menuDialog.close()));
document.querySelectorAll('[data-booking-form]').forEach((form) => {
  form.addEventListener('submit', (event) => {
    event.preventDefault();
    const details = new FormData(form);
    openBooking({ checkIn: details.get('checkIn'), checkOut: details.get('checkOut'), guests: details.get('guests') });
  });
});
document.querySelector('#closeDialog').addEventListener('click', () => dialog.close());
document.querySelector('#closeBooking').addEventListener('click', () => dialog.close());
dialog.addEventListener('click', (event) => { if (event.target === dialog) dialog.close(); });

document.querySelectorAll('[data-gallery]').forEach((gallery) => {
  const mainImage = gallery.querySelector('.villa-gallery__main');
  gallery.querySelectorAll('[data-gallery-image]').forEach((button) => {
    button.addEventListener('click', () => {
      mainImage.src = button.dataset.galleryImage;
      mainImage.alt = button.dataset.galleryAlt;
      gallery.querySelectorAll('[data-gallery-image]').forEach((item) => item.classList.toggle('is-selected', item === button));
    });
  });
});

document.querySelectorAll('.menu-dialog nav a').forEach((link) => {
  if (link.textContent.trim() === 'Dining') link.href = 'dining.html';
  if (link.textContent.trim() === 'Explore') link.href = 'explore.html';
});
const mobileLogoQuery = window.matchMedia('(max-width: 700px)');
const syncBrandMarks = () => {
  const source = mobileLogoQuery.matches
    ? 'Pics/Brand/breathe-woods-wordmark-mobile-white.png'
    : 'Pics/Brand/logowordmarkwhite.png';
  document.querySelectorAll('.brand img, .site-footer__brand img').forEach((logo) => {
    logo.src = source;
    logo.alt = 'Breathe Woods';
  });
};
syncBrandMarks();
mobileLogoQuery.addEventListener('change', syncBrandMarks);
document.querySelectorAll('.menu-dialog a').forEach((link) => {
  if (link.textContent.trim() === 'Contact') link.href = 'contact.html';
  if (link.textContent.trim() === 'Information') link.href = 'information.html';
  if (link.textContent.trim() === 'Dining') link.href = 'dining.html';
  if (link.textContent.trim() === 'Explore') link.href = 'explore.html';
});

document.querySelectorAll('.menu-dialog .eyebrow.dark').forEach((label) => {
  label.classList.add('menu-brand-mark');
  label.innerHTML = '<img src="Pics/Brand/desktop-breathe-woods-logo.png" alt="Breathe Woods">';
});
