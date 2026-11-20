// Keeps the browser's install prompt so the app's Install button can show it
// later. A separate file because the site's CSP blocks inline scripts.
window.socketagentInstallPrompt = null;
window.addEventListener('beforeinstallprompt', (event) => {
  event.preventDefault();
  window.socketagentInstallPrompt = event;
});
window.addEventListener('appinstalled', () => {
  window.socketagentInstallPrompt = null;
});
