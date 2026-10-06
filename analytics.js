(() => {
  // Keep private owner-dashboard activity out of the public GA4 property.
  if (/(?:^|\/)book\/owner(?:\/|$)/.test(window.location.pathname)) return;

  window.dataLayer = window.dataLayer || [];
  window.gtag = window.gtag || function gtag() { window.dataLayer.push(arguments); };
  window.gtag('js', new Date());
  window.gtag('config', 'G-E3L86VXX1M');

  const tag = document.createElement('script');
  tag.async = true;
  tag.src = 'https://www.googletagmanager.com/gtag/js?id=G-E3L86VXX1M';
  document.head.appendChild(tag);

  const eventForLink = (link) => {
    const href = link.getAttribute('href') || '';
    if (href.includes('wa.me')) return 'whatsapp_click';
    if (href.startsWith('tel:')) return 'call_click';
    if (href.includes('instagram.com')) return 'instagram_click';
    return null;
  };

  document.addEventListener('click', (event) => {
    const link = event.target.closest?.('a');
    const linkEvent = link && eventForLink(link);
    if (linkEvent) window.gtag('event', linkEvent, { link_url: link.href });

    const bookingTrigger = event.target.closest?.('[data-book], [data-booking-form] button[type="submit"]');
    if (bookingTrigger) window.gtag('event', 'booking_start', { source: bookingTrigger.textContent.trim() });
  });

  document.addEventListener('submit', (event) => {
    if (event.target.matches?.('.enquiry-form')) window.gtag('event', 'enquiry_submit');
  });
})();
