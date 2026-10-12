(() => {
  'use strict';
  const link = document.getElementById('rift-enter');
  const configured = window.GAME_PORTAL_CONFIG?.riftUrl;
  if (link && typeof configured === 'string' && configured.startsWith('/') && !configured.startsWith('//')) {
    link.href = configured;
  }
})();
