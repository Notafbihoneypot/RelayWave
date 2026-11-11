// RelayWave theme switch. Classic stays the default; retro is opt-in.
// Loaded as a same-origin file because the app's CSP forbids inline scripts.
// Touches nothing but a data attribute, one localStorage key and one button:
// no network requests, no identity or signing code.
(() => {
  const KEY = 'rw_theme';
  const root = document.documentElement;
  let theme = 'classic';
  try {
    const asked = new URLSearchParams(location.search).get('theme');
    if (asked === 'retro' || asked === 'classic') localStorage.setItem(KEY, asked);
    if (localStorage.getItem(KEY) === 'retro') theme = 'retro';
  } catch { /* storage blocked: stay on classic */ }
  root.dataset.theme = theme;

  document.addEventListener('DOMContentLoaded', () => {
    const bar = document.querySelector('.top-actions');
    if (!bar) return;
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'button ghost';
    button.id = 'themeToggleBtn';
    const label = () => {
      const retro = root.dataset.theme === 'retro';
      button.textContent = retro ? 'Classic theme' : 'Retro theme';
      button.setAttribute('aria-pressed', String(retro));
    };
    button.addEventListener('click', () => {
      root.dataset.theme = root.dataset.theme === 'retro' ? 'classic' : 'retro';
      try { localStorage.setItem(KEY, root.dataset.theme); } catch { /* not persisted */ }
      label();
    });
    label();
    bar.prepend(button);
  });
})();
