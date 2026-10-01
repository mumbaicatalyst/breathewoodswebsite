const arrival = document.querySelector('#arrival');
const arrivalVideo = document.querySelector('#arrivalVideo');
const skipArrival = document.querySelector('#skipArrival');
const header = document.querySelector('#siteHeader');
const dialog = document.querySelector('#bookingDialog');
const menuDialog = document.querySelector('#menuDialog');
const sequence = document.querySelector('.hero-sequence');
const frames = [...document.querySelectorAll('.hero-frame')];
const scrollCue = document.querySelector('#scrollCue');
const readyFrames = new Set([0]);

frames.forEach((frame, index) => {
  const image = frame.querySelector('img');
  if (!image || index === 0) return;
  const markReady = () => {
    const decoded = image.decode ? image.decode().catch(() => {}) : Promise.resolve();
    decoded.then(() => {
      readyFrames.add(index);
      updateSequence();
    });
  };
  if (image.complete) markReady();
  else {
    image.addEventListener('load', markReady, { once: true });
    image.addEventListener('error', () => {
      readyFrames.add(index);
      updateSequence();
    }, { once: true });
  }
});

const connection = navigator.connection;
const prefersReducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
const canLoadIntroVideo = !prefersReducedMotion && !connection?.saveData && (!connection || /^(4g|5g)$/.test(connection.effectiveType || '')) && window.matchMedia('(min-width: 701px)').matches;

function attachDeferredVideo(video, autoplay = false) {
  if (!video || video.dataset.loaded === 'true' || !video.dataset.src) return;
  const source = document.createElement('source');
  source.src = video.dataset.src;
  source.type = 'video/mp4';
  video.append(source);
  video.dataset.loaded = 'true';
  video.preload = autoplay ? 'auto' : 'metadata';
  video.load();
  if (autoplay) video.play().catch(() => {});
}

function tightenMenu(dialogElement) {
  dialogElement.setAttribute('aria-label', 'Site menu');
  dialogElement.removeAttribute('aria-labelledby');
  dialogElement.querySelector('h2')?.remove();
  const oldLinks = dialogElement.querySelector('.menu-social');
  if (oldLinks) oldLinks.outerHTML = '<div class="menu-contact-links" aria-label="Contact Breathe Woods"><a href="https://wa.me/919967786444" aria-label="Message Breathe Woods on WhatsApp"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M20.5 11.6a8.3 8.3 0 0 1-12.25 7.3L4 20l1.15-4.05A8.3 8.3 0 1 1 20.5 11.6Z"/><path d="M9 8.2c.2-.4.4-.4.6-.4h.4c.2 0 .3.1.4.3l.6 1.5c.1.2.1.3 0 .5l-.3.4c-.1.2-.1.3 0 .5.3.6.9 1.2 1.6 1.6.2.1.3.1.5 0l.5-.6c.1-.2.3-.2.5-.1l1.5.7c.2.1.3.2.3.4 0 .5-.2 1-.6 1.3-.5.3-1.3.3-2.4-.2-1-.5-2.1-1.3-3.1-2.3-1-1-1.7-2.1-2.1-3.1-.3-.9-.1-1.7.2-2.2Z"/></svg></a><a href="tel:+919967786444" aria-label="Call Breathe Woods"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M7.1 3.7 9.5 6c.32.32.38.82.15 1.2L8.5 9.2a14.2 14.2 0 0 0 6.3 6.3l2-1.15c.39-.23.88-.17 1.2.15l2.3 2.4c.34.35.37.9.06 1.28l-1.25 1.48c-.37.44-.96.64-1.52.5C10.1 18.2 5.8 13.9 3.84 6.41c-.15-.56.06-1.15.5-1.52l1.48-1.25c.38-.3.93-.28 1.28.06Z"/></svg></a></div>';
}
tightenMenu(menuDialog);

const introMinimumDuration = canLoadIntroVideo ? 4600 : 650;
const arrivalStartedAt = performance.now();
let arrivalFinished = false;

if (canLoadIntroVideo) {
  attachDeferredVideo(arrivalVideo, true);
} else {
  arrival.classList.add('no-motion');
}

function finishArrival(force = false) {
  if (arrivalFinished) return;
  const remaining = introMinimumDuration - (performance.now() - arrivalStartedAt);
  if (!force && remaining > 0) {
    window.setTimeout(() => finishArrival(), remaining);
    return;
  }
  arrivalFinished = true;
  arrival.classList.add('done');
}

arrivalVideo.addEventListener('ended', finishArrival);
arrivalVideo.addEventListener('error', () => finishArrival(true));
skipArrival.addEventListener('click', () => finishArrival(true));
window.setTimeout(finishArrival, introMinimumDuration);

const deferredVideos = [...document.querySelectorAll('video[data-src]:not(#arrivalVideo)')];
if ('IntersectionObserver' in window) {
  const videoObserver = new IntersectionObserver((entries, observer) => {
    entries.forEach((entry) => {
      if (!entry.isIntersecting) return;
      attachDeferredVideo(entry.target);
      observer.unobserve(entry.target);
    });
  }, { rootMargin: '400px 0px' });
  deferredVideos.forEach((video) => videoObserver.observe(video));
} else {
  deferredVideos.forEach((video) => attachDeferredVideo(video));
}

const ranges = [[0, .215], [.20, .415], [.40, .615], [.60, .815], [.80, 1]];
const clamp = (value, min = 0, max = 1) => Math.min(max, Math.max(min, value));

function smooth(value) {
  const t = clamp(value);
  return t * t * (3 - 2 * t);
}

function sceneStrength(progress, start, end) {
  const edge = Math.min(.03, (end - start) / 2);
  const fadeIn = start === 0 ? 1 : smooth((progress - start) / edge);
  const fadeOut = end === 1 ? 1 : 1 - smooth((progress - (end - edge)) / edge);
  return fadeIn * fadeOut;
}

function updateSequence() {
  const rect = sequence.getBoundingClientRect();
  const travel = Math.max(1, sequence.offsetHeight - window.innerHeight);
  const progress = clamp(-rect.top / travel);
  const strengths = frames.map((frame, index) => sceneStrength(progress, ...ranges[index]));
  if (strengths.some((strength, index) => strength > .01 && !readyFrames.has(index))) return;

  frames.forEach((frame, index) => {
    const strength = strengths[index];
    const midpoint = (ranges[index][0] + ranges[index][1]) / 2;
    const scale = 1.075 - strength * .065 + Math.abs(progress - midpoint) * .018;
    const reveal = smooth(clamp((strength - .06) / .72));

    frame.style.setProperty('--scene-opacity', strength.toFixed(3));
    frame.style.setProperty('--copy-opacity', reveal.toFixed(3));
    frame.style.setProperty('--copy-shift', `${(1 - reveal) * 34}px`);
    frame.style.setProperty('--copy-blur', `${(1 - reveal) * 7}px`);
    frame.style.setProperty('--copy-reveal', reveal.toFixed(3));
    frame.style.setProperty('--copy-clip', `${(1 - reveal) * 100}%`);
    frame.style.setProperty('--scene-scale', scale.toFixed(3));
    frame.style.setProperty('--mobile-position', frame.dataset.mobilePosition);
    frame.classList.toggle('is-active', strength > .5);
  });

  scrollCue.style.opacity = String(clamp(1 - progress * 7));
  header.classList.toggle('scrolled', window.scrollY > 40);
}

let ticking = false;
window.addEventListener('scroll', () => {
  if (ticking) return;
  requestAnimationFrame(() => {
    updateSequence();
    ticking = false;
  });
  ticking = true;
}, { passive: true });

window.addEventListener('resize', updateSequence);
updateSequence();

document.querySelectorAll('[data-book]').forEach((button) => {
  button.addEventListener('click', () => {
    if (menuDialog.open) menuDialog.close();
    dialog.showModal();
  });
});
document.querySelector('#openMenu').addEventListener('click', () => menuDialog.showModal());
document.querySelector('#closeMenu').addEventListener('click', () => menuDialog.close());
menuDialog.querySelectorAll('a').forEach((link) => {
  link.addEventListener('click', () => menuDialog.close());
});
document.querySelectorAll('[data-booking-form]').forEach((form) => {
  form.addEventListener('submit', (event) => {
    event.preventDefault();
    const details = new FormData(form);
    const checkIn = details.get('checkIn');
    const checkOut = details.get('checkOut');
    const guests = details.get('guests');
    const summary = document.querySelector('#bookingSummary');
    summary.textContent = `Requested stay: ${checkIn || 'choose check-in'} to ${checkOut || 'choose check-out'} · ${guests} guest${guests === '1' ? '' : 's'}. The final site will pass these details to the approved booking system.`;
    dialog.showModal();
  });
});
document.querySelector('#closeDialog').addEventListener('click', () => dialog.close());
document.querySelector('#closeBooking').addEventListener('click', () => dialog.close());
dialog.addEventListener('click', (event) => {
  if (event.target === dialog) dialog.close();
});

document.querySelectorAll('.menu-dialog nav a').forEach((link) => {
  if (link.textContent.trim() === 'Dining') link.href = 'dining.html';
  if (link.textContent.trim() === 'Explore') link.href = 'explore.html';
});
document.querySelectorAll('.brand img, .site-footer__brand img').forEach((logo) => {
  logo.src = 'Pics/Brand/logowordmarkwhite.png';
  logo.alt = 'Breathe Woods';
});
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
