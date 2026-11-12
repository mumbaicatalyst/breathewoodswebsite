(() => {
  const productionHosts = new Set(['breathewoods.com', 'www.breathewoods.com']);
  const isOwnerRoute = /(?:^|\/)book\/owner(?:\/|$)/.test(window.location.pathname);

  // Keep local, preview, and private owner activity out of the production GA4 property.
  if (!productionHosts.has(window.location.hostname) || isOwnerRoute) return;

  window.dataLayer = window.dataLayer || [];
  window.gtag = window.gtag || function gtag() { window.dataLayer.push(arguments); };
  window.gtag('js', new Date());
  window.gtag('config', 'G-E3L86VXX1M');

  const script = document.createElement('script');
  script.async = true;
  script.src = 'https://www.googletagmanager.com/gtag/js?id=G-E3L86VXX1M';
  document.head.appendChild(script);
})();
