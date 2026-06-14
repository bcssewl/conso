/* conso mockups — shared theme switcher with persistence across pages */
(function () {
  const root = document.documentElement;
  const seg = document.getElementById('seg');
  const app = document.getElementById('app');

  function apply(t, a) {
    root.setAttribute('data-theme', t);
    root.setAttribute('data-appearance', a);
    if (seg) [...seg.children].forEach(x => x.classList.toggle('active', x.dataset.t === t));
    if (app) {
      const pro = t === 'pro';
      [...app.children].forEach(x => {
        x.disabled = pro;
        x.classList.toggle('active', x.dataset.a === a);
      });
    }
  }

  const t0 = localStorage.getItem('conso-theme') || 'native';
  const a0 = t0 === 'pro' ? 'dark' : (localStorage.getItem('conso-appearance') || 'light');
  apply(t0, a0);

  if (seg) seg.addEventListener('click', e => {
    const b = e.target.closest('button[data-t]'); if (!b) return;
    const t = b.dataset.t;
    const a = t === 'pro' ? 'dark' : (localStorage.getItem('conso-appearance') || 'light');
    localStorage.setItem('conso-theme', t);
    apply(t, a);
  });

  if (app) app.addEventListener('click', e => {
    const b = e.target.closest('button[data-a]'); if (!b || b.disabled) return;
    localStorage.setItem('conso-appearance', b.dataset.a);
    apply(root.getAttribute('data-theme'), b.dataset.a);
  });
})();
