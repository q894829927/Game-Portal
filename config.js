// Production route reserved for Rift Resonance after its front-end base path
// and WebSocket proxy have been migrated. Do not publish to the ECS root
// before completing the migration checklist in docs/DEPLOY.md.
window.GAME_PORTAL_CONFIG = Object.freeze({
  riftUrl: '/games/rift/'
});
