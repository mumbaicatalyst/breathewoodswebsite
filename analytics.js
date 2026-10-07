(() => {
  // Keep private owner-dashboard activity out of the public GA4 property.
  if (/(?:^|\/)book\/owner(?:\/|$)/.test(window.location.pathname)) return;

  const eventForLink = (link) => {
    const href = link.getAttribute('href') || '';
    if (href.includes('wa.me')) return 'whatsapp_click';
    if (href.startsWith('tel:')) return 'call_click';
    if (href.startsWith('mailto:')) return 'email_click';
    if (href.includes('instagram.com')) return 'instagram_click';
    if (href.includes('facebook.com')) return 'facebook_click';
    if (href.includes('youtube.com')) return 'youtube_click';
    if (href.includes('google.com/maps') || href.includes('maps.app.goo.gl')) return 'maps_click';
    return null;
  };

  document.addEventListener('click', (event) => {
    const link = event.target.closest?.('a');
    const linkEvent = link && eventForLink(link);
    if (linkEvent) window.gtag?.('event', linkEvent, { link_url: link.href });

    const bookingTrigger = event.target.closest?.('[data-book], [data-booking-form] button[type="submit"]');
    if (bookingTrigger) window.gtag?.('event', 'booking_start', { source: bookingTrigger.textContent.trim() });
  });

  document.addEventListener('submit', (event) => {
    if (event.target.matches?.('.enquiry-form')) window.gtag?.('event', 'enquiry_submit');
  });
})();
