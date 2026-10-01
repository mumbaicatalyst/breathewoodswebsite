(() => {
  const base = 'https://www.breathewoods.com';
  const pages = {
    '/': {
      title: 'Breathe Woods — Private Nature Retreat in Raigad',
      description: 'Breathe Woods is a private six-and-a-half-acre nature retreat in Raigad, Maharashtra, with two private villas, rain-fed water, gardens, and unhurried stays.'
    },
    '/index.html': {
      title: 'Breathe Woods — Private Nature Retreat in Raigad',
      description: 'Breathe Woods is a private six-and-a-half-acre nature retreat in Raigad, Maharashtra, with two private villas, rain-fed water, gardens, and unhurried stays.'
    },
    '/stays.html': { title: 'Stays at Breathe Woods — Private Villas in Raigad', description: 'Stay at Breathe Woods in Raigad, Maharashtra: two private villas, five bedrooms, room stays, breakfast, and space for families, groups, and pets.' },
    '/property.html': { title: 'The Property — Breathe Woods in Raigad', description: 'Explore Breathe Woods, a six-and-a-half-acre nature retreat in Raigad with forest, water, gardens, trails, and two private villas.' },
    '/dining.html': { title: 'By the Bruk — Dining at Breathe Woods', description: 'Dine at By the Bruk at Breathe Woods in Raigad, with breakfast included and seasonal Maharashtrian-inspired meals served among the gardens.' },
    '/explore.html': { title: 'Explore Around Breathe Woods in Raigad', description: 'Explore the green around Breathe Woods in Raigad: forest trails, water, picnics, bonfires, cycling, camping, and pet-friendly outdoor days.' },
    '/information.html': { title: 'Plan Your Stay — Breathe Woods Information', description: 'Plan a stay at Breathe Woods in Raigad with practical details on arrival, seasons, meals, directions, pets, and what to bring.' },
    '/contact.html': { title: 'Contact Breathe Woods — Plan Your Stay', description: 'Contact Breathe Woods to plan a private villa or room stay in Raigad, Maharashtra. Ask about dates, meals, pets, directions, and availability.' }
  };
  const pagePath = window.location.pathname
    .replace(/^\/netlify-preview/, '')
    .replace(/\/+/g, '/')
    .replace(/\/index\.html$/, '/') || '/';
  const page = pages[pagePath] || pages['/'];
  const canonical = `${base}${pagePath}`;
  const navTargets = { Dining: 'dining.html', Explore: 'explore.html', Information: 'information.html', Contact: 'contact.html' };
  document.querySelectorAll('.menu-dialog nav a').forEach((link) => {
    const target = navTargets[link.textContent.trim()];
    if (target) link.href = target;
  });
  const setMeta = (name, content, attribute = 'name') => {
    let node = document.head.querySelector(`meta[${attribute}="${name}"]`);
    if (!node) { node = document.createElement('meta'); node.setAttribute(attribute, name); document.head.append(node); }
    node.content = content;
  };
  document.title = page.title;
  setMeta('description', page.description);
  setMeta('og:title', page.title, 'property');
  setMeta('og:description', page.description, 'property');
  setMeta('og:type', 'website', 'property');
  setMeta('og:url', canonical, 'property');
  setMeta('twitter:card', 'summary_large_image');
  if (!document.head.querySelector('link[rel="canonical"]')) {
    const link = document.createElement('link'); link.rel = 'canonical'; link.href = canonical; document.head.append(link);
  }
  if (!document.head.querySelector('script[data-breathe-schema], script[type="application/ld+json"]')) {
    const schema = document.createElement('script');
    schema.type = 'application/ld+json';
    schema.dataset.breatheSchema = 'true';
    schema.textContent = JSON.stringify({
      '@context': 'https://schema.org',
      '@type': 'LodgingBusiness',
      '@id': `${base}/#lodging`,
      name: 'Breathe Woods',
      url: base,
      description: 'A private six-and-a-half-acre nature retreat in Raigad, Maharashtra, with two private villas.',
      telephone: '+919967786444',
      email: 'breathewoods@gmail.com',
      address: { '@type': 'PostalAddress', streetAddress: 'Kakadshet Road, Off Tala–Indapur Road, Muthavli Village', addressLocality: 'Indapur', addressRegion: 'Maharashtra', postalCode: '402120', addressCountry: 'IN' },
      sameAs: ['https://www.instagram.com/breathewoodstala/', 'https://www.youtube.com/@breathewoods-anaturestay5597', 'https://maps.app.goo.gl/fBLHygWwvHLbT3ox7']
    });
    document.head.append(schema);
  }
})();
