const destination = 'Breathe+Woods%2C+Muthavli+Village%2C+Indapur%2C+Raigad%2C+Maharashtra+402120';
const routeCopy = {
  mumbai: { name: 'Mumbai', time: '2½ hours', distance: 'About 133 km · via NH 66', guide: ['Leave Mumbai on the fastest live route out of the city.', 'Join NH 66 and continue south towards Mangaon.', 'At Indapur, take the Tala–Indapur Road to Muthavli.'], highways: [{ name: 'Atal Setu', coordinates: [72.9907, 18.9812], place: true }, { name: 'NH 66', at: .54 }, { name: 'Tala–Indapur Rd', at: .88, dx: -28, dy: -16 }], coastal: true, maps: `https://www.google.com/maps/dir/?api=1&origin=Mumbai%2C+Maharashtra&destination=${destination}` },
  csmia: { name: 'Mumbai Airport', time: '3 hours', distance: 'About 151 km · via Atal Setu & NH 66', guide: ['Leave the airport for Atal Setu, crossing towards Navi Mumbai.', 'Continue via Panvel and Pen, then join NH 66 south towards Mangaon.', 'At Indapur, take the Tala–Indapur Road to Muthavli.'], highways: [{ name: 'Atal Setu', coordinates: [72.9907, 18.9812], place: true }, { name: 'NH 66', at: .56 }, { name: 'Tala–Indapur Rd', at: .88, dx: -28, dy: -16 }], coastal: true, maps: `https://www.google.com/maps/dir/?api=1&origin=Chhatrapati+Shivaji+Maharaj+International+Airport&destination=${destination}` },
  nmia: { name: 'Navi Mumbai Airport', time: '2 hours', distance: 'About 108 km · via NH 66', guide: ['Leave the airport towards the JNPT and Panvel approach roads.', 'Join NH 66 and continue south towards Mangaon.', 'At Indapur, take the Tala–Indapur Road to Muthavli.'], highways: [{ name: 'NH 66', at: .52 }, { name: 'Tala–Indapur Rd', at: .88, dx: -28, dy: -16 }], coastal: true, maps: `https://www.google.com/maps/dir/?api=1&origin=Navi+Mumbai+International+Airport&destination=${destination}` },
  naviMumbai: { name: 'Navi Mumbai', time: '2¼ hours', distance: 'About 112 km · via NH 66', guide: ['Head south through the Panvel and JNPT approach roads.', 'Join NH 66 and continue south towards Mangaon.', 'At Indapur, take the Tala–Indapur Road to Muthavli.'], highways: [{ name: 'NH 66', at: .5 }, { name: 'Tala–Indapur Rd', at: .88, dx: -28, dy: -16 }], coastal: true, maps: `https://www.google.com/maps/dir/?api=1&origin=Navi+Mumbai%2C+Maharashtra&destination=${destination}` },
  thane: { name: 'Thane', time: '3¼ hours', distance: 'About 131 km · via NH 66', guide: ['Take the fastest live connection towards Navi Mumbai or the Sion–Panvel corridor.', 'Join NH 66 and continue south towards Mangaon.', 'At Indapur, take the Tala–Indapur Road to Muthavli.'], highways: [{ name: 'NH 66', at: .58 }, { name: 'Tala–Indapur Rd', at: .88, dx: -28, dy: -16 }], coastal: true, maps: `https://www.google.com/maps/dir/?api=1&origin=Thane%2C+Maharashtra&destination=${destination}` },
  pune: { name: 'Pune', time: '3 hours', distance: 'About 121 km · via NH 753F', guide: ['Leave Pune on the western route towards Mulshi and the Tamhini side.', 'Continue on NH 753F towards Mangaon.', 'At Indapur, take the Tala–Indapur Road to Muthavli.'], highways: [{ name: 'Tamhini Ghat', at: .36 }, { name: 'NH 753F', at: .64 }, { name: 'Tala–Indapur Rd', at: .88, dx: -28, dy: -16 }], coastal: false, maps: `https://www.google.com/maps/dir/?api=1&origin=Pune%2C+Maharashtra&destination=${destination}` },
};

const mapData = window.BreatheWoodsRouteMap;
const select = document.querySelector('#route-origin-select');
const svg = document.querySelector('.drive-map-svg');
const baseRoads = document.querySelector('#drive-base-roads');
const coastline = document.querySelector('#drive-coastline');
const underlay = document.querySelector('#drive-route-underlay');
const line = document.querySelector('#drive-route-line');
const shadow = document.querySelector('#drive-route-shadow');
const dots = document.querySelector('#drive-route-dots');
const routeLabels = document.querySelector('#drive-route-labels');
const seaLabel = document.querySelector('#drive-sea-label');
const stateLabel = document.querySelector('#drive-state-label');
const origin = document.querySelector('#drive-origin');
const originLabel = document.querySelector('#drive-origin-label');
const destinationMarker = document.querySelector('#drive-destination');
const destinationLabel = document.querySelector('#drive-destination-label');
const destinationSub = document.querySelector('#drive-destination-sub');
const mapOrigin = document.querySelector('#route-map-origin');
const mapTime = document.querySelector('#route-map-time');
const duration = document.querySelector('#route-duration');
const distance = document.querySelector('#route-distance');
const guide = document.querySelector('#route-guide');
const maps = document.querySelector('#route-maps-link');

function pathFrom(points) { return points.map(([x, y], index) => `${index ? 'L' : 'M'}${x} ${y}`).join(''); }

function routeViewport(points) {
  const xs = points.map(([x]) => x); const ys = points.map(([, y]) => y);
  let minX = Math.min(...xs); let maxX = Math.max(...xs); let minY = Math.min(...ys); let maxY = Math.max(...ys);
  const routeWidth = Math.max(maxX - minX, 180); const routeHeight = Math.max(maxY - minY, 160);
  const padding = Math.max(62, Math.max(routeWidth, routeHeight) * .16);
  minX -= padding; maxX += padding; minY -= padding; maxY += padding;
  let width = maxX - minX; let height = maxY - minY;
  const ratio = svg.clientWidth && svg.clientHeight ? svg.clientWidth / svg.clientHeight : 640 / 440;
  if (width / height < ratio) { const extra = (height * ratio - width) / 2; minX -= extra; width += extra * 2; }
  else { const extra = (width / ratio - height) / 2; minY -= extra; height += extra * 2; }
  return { viewBox: `${minX} ${minY} ${width} ${height}`, minX, minY, width, height };
}

function pointsForTrail(points, count = 22) { return Array.from({ length: count }, (_, index) => points[Math.round((index / (count - 1)) * (points.length - 1))]); }
function project([lon, lat]) { const { bounds } = mapData; return [((lon - bounds.minLon) / (bounds.maxLon - bounds.minLon)) * bounds.width, ((bounds.maxLat - lat) / (bounds.maxLat - bounds.minLat)) * bounds.height]; }
function routeLabelMarkup(label, points) {
  const [x, y] = label.coordinates || points[Math.round((points.length - 1) * label.at)];
  if (label.place) return `<text class="drive-map-place-label" x="${x}" y="${y - 18}" text-anchor="middle">${label.name}</text>`;
  const width = Math.max(46, label.name.length * 6.1 + 18); const dx = label.dx ?? 14; const dy = label.dy ?? -14;
  return `<g class="drive-highway-label" transform="translate(${x + dx} ${y + dy})"><rect x="${-width / 2}" y="-12" width="${width}" height="20" rx="2"/><text text-anchor="middle" y="2.5">${label.name}</text></g>`;
}

if (mapData && select && svg) {
  baseRoads.innerHTML = mapData.roads.map((road) => `<path class="drive-road drive-road--${road.kind}" d="${road.d}"/>`).join('');
  coastline.innerHTML = mapData.coastline.map((d) => `<path class="drive-coastline" d="${d}"/>`).join('');

  function renderRoute(key) {
    const copy = routeCopy[key]; const route = mapData.routes[key];
    const [startX, startY] = route.points[0]; const [endX, endY] = route.points[route.points.length - 1]; const path = pathFrom(route.points);
    const viewport = routeViewport(route.points);
    svg.setAttribute('viewBox', viewport.viewBox); underlay.setAttribute('d', path); line.setAttribute('d', path); shadow.setAttribute('d', path);
    origin.setAttribute('transform', `translate(${startX} ${startY})`); destinationMarker.setAttribute('transform', `translate(${endX} ${endY})`);
    originLabel.setAttribute('y', -24); originLabel.textContent = copy.name; destinationLabel.setAttribute('y', 34); destinationSub.setAttribute('y', 50);
    dots.innerHTML = pointsForTrail(route.points).map(([cx, cy], index) => `<circle class="drive-route-dot" cx="${cx}" cy="${cy}" r="4" style="animation-delay:${index * .13}s"></circle>`).join('');
    routeLabels.innerHTML = copy.highways.map((label) => routeLabelMarkup(label.coordinates ? { ...label, coordinates: project(label.coordinates) } : label, route.points)).join('');
    stateLabel.setAttribute('display', key === 'pune' ? 'none' : 'block'); stateLabel.setAttribute('x', viewport.minX + viewport.width * .76); stateLabel.setAttribute('y', viewport.minY + viewport.height * .18);
    seaLabel.setAttribute('display', copy.coastal ? 'block' : 'none'); seaLabel.setAttribute('x', viewport.minX + viewport.width * .14); seaLabel.setAttribute('y', viewport.minY + viewport.height * .78);
    const length = line.getTotalLength(); line.style.strokeDasharray = `${length}`; line.style.strokeDashoffset = `${length}`; shadow.style.strokeDasharray = `${length}`; shadow.style.strokeDashoffset = `${length}`;
    line.classList.remove('is-animating'); shadow.classList.remove('is-animating'); requestAnimationFrame(() => { line.classList.add('is-animating'); shadow.classList.add('is-animating'); });
    mapOrigin.textContent = copy.name; mapTime.textContent = `Typical drive · ${copy.time}`; duration.textContent = copy.time; distance.textContent = copy.distance;
    guide.innerHTML = copy.guide.map((step) => `<li>${step}</li>`).join(''); maps.href = copy.maps;
  }

  select.addEventListener('change', () => renderRoute(select.value));
  let resizeFrame;
  window.addEventListener('resize', () => { cancelAnimationFrame(resizeFrame); resizeFrame = requestAnimationFrame(() => renderRoute(select.value)); });
  renderRoute(select.value);
}
