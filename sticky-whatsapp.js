(() => {
  if (document.querySelector('.sticky-whatsapp')) return;

  const link = document.createElement('a');
  link.className = 'sticky-whatsapp';
  link.href = 'https://wa.me/919967786444';
  link.target = '_blank';
  link.rel = 'noopener noreferrer';
  link.setAttribute('aria-label', 'Chat with Breathe Woods on WhatsApp');
  link.title = 'Chat with Breathe Woods on WhatsApp';
  link.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M20.5 11.6a8.3 8.3 0 0 1-12.25 7.3L4 20l1.15-4.05A8.3 8.3 0 1 1 20.5 11.6Z"/><path d="M8.7 8.3c.18-.4.36-.4.53-.4h.46c.14 0 .35.05.44.36l.6 1.46c.08.2.04.36-.04.5l-.27.43c-.1.14-.2.28-.08.5.12.2.55.9 1.19 1.46.82.72 1.5.94 1.72 1.05.2.1.33.08.45-.05l.58-.68c.13-.16.3-.2.5-.12l1.5.72c.24.12.4.18.46.3.06.12.06.7-.15 1.34-.2.64-1.18 1.23-1.63 1.28-.42.05-.94.2-3.17-.7-2.68-1.1-4.4-3.78-4.53-3.96-.13-.18-1.08-1.44-1.08-2.74 0-1.3.68-1.94.92-2.2Z"/></svg>';
  document.body.appendChild(link);
})();
