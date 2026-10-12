(() => {
  'use strict';
  const config = window.GAME_PORTAL_CONFIG;
  for (const [id, route] of [
    ['rift-enter', config?.riftUrl],
    ['tactics-enter', config?.tacticsUrl]
  ]) {
    const link = document.getElementById(id);
    if (link && typeof route === 'string' &&
        route.startsWith('/') && !route.startsWith('//')) {
      link.href = route;
    }
  }
})();
