const routes = {
  airport: { label: 'Mumbai Airport', time: 'About 3 hours', detail: 'A broad journey south-east into Raigad.', point: [145, 128], path: 'M145 128 C228 160 287 193 348 238 C435 300 542 314 647 372 C716 410 787 424 844 452', origin: 'Chhatrapati+Shivaji+Maharaj+International+Airport' },
  mumbai: { label: 'Mumbai', time: 'About 3 hours', detail: 'A south-east route towards the forests of Raigad.', point: [94, 96], path: 'M94 96 C198 131 276 190 358 244 C471 317 591 354 677 393 C740 421 790 438 844 452', origin: 'Mumbai%2C+Maharashtra' },
  navi: { label: 'Navi Mumbai', time: 'About 2.5–3 hours', detail: 'A shorter start, then steadily into the hills.', point: [247, 177], path: 'M247 177 C339 215 402 266 484 309 C600 371 706 401 844 452', origin: 'Navi+Mumbai%2C+Maharashtra' },
  thane: { label: 'Thane', time: 'About 3 hours', detail: 'From the north-east of Mumbai into Raigad.', point: [170, 55], path: 'M170 55 C257 130 340 170 407 244 C514 357 656 403 844 452', origin: 'Thane%2C+Maharashtra' },
  pune: { label: 'Pune', time: 'About 3 hours', detail: 'Across the Ghats, then down towards the coast.', point: [826, 113], path: 'M826 113 C742 161 693 221 671 288 C647 359 704 405 844 452', origin: 'Pune%2C+Maharashtra' },
  nashik: { label: 'Nashik', time: 'About 5 hours', detail: 'A longer road south through Maharashtra.', point: [480, 54], path: 'M480 54 C430 149 455 220 525 287 C604 363 695 412 844 452', origin: 'Nashik%2C+Maharashtra' }
};
const path = document.querySelector('#route-line');
const marker = document.querySelector('#origin-marker');
const pulse = document.querySelector('#route-pulse');
const label = document.querySelector('#origin-label');
const routeOrigin = document.querySelector('#route-origin');
const routeTime = document.querySelector('#route-time');
const detail = document.querySelector('#route-detail');
const maps = document.querySelector('#maps-link');
const tabs = [...document.querySelectorAll('[data-origin]')];
function selectRoute(key) {
  const route = routes[key];
  path.setAttribute('d', route.path); marker.setAttribute('cx', route.point[0]); marker.setAttribute('cy', route.point[1]); pulse.setAttribute('cx', route.point[0]); pulse.setAttribute('cy', route.point[1]); label.setAttribute('x', route.point[0]); label.setAttribute('y', Math.max(26, route.point[1] - 20)); label.textContent = route.label; routeOrigin.textContent = route.label; routeTime.textContent = route.time; detail.textContent = route.detail; maps.href = `https://www.google.com/maps/dir/?api=1&origin=${route.origin}&destination=Kakadshet+Road%2C+Muthavli+Village%2C+Indapur%2C+Raigad%2C+Maharashtra+402120`;
  path.classList.remove('draw-route'); void path.getBoundingClientRect(); path.classList.add('draw-route');
  tabs.forEach((tab) => { const active = tab.dataset.origin === key; tab.classList.toggle('is-active', active); tab.setAttribute('aria-selected', active); });
}
tabs.forEach((tab) => tab.addEventListener('click', () => selectRoute(tab.dataset.origin)));
selectRoute('airport');
