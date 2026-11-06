// Number keys jump between sections, as the key hints in the top line say; the section in view takes the accent,
// as a focused pane does. The page works the same without this script.
(() => {
  const keys = [...document.querySelectorAll('.keys [data-key]')];
  addEventListener('keydown', (event) => {
    if (event.metaKey || event.ctrlKey || event.altKey) return;
    if (/input|textarea|select/i.test(event.target.tagName)) return;
    const key = keys.find((link) => link.dataset.key === event.key);
    if (!key) return;
    event.preventDefault();
    location.hash = key.getAttribute('href').slice(1);
  });

  const panes = [...document.querySelectorAll('[data-spy]')];
  if (!('IntersectionObserver' in window)) return;
  const observer = new IntersectionObserver((entries) => {
    const hit = entries
      .filter((entry) => entry.isIntersecting)
      .sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top)[0];
    if (!hit) return;
    panes.forEach((pane) => pane.classList.toggle('is-cur', pane === hit.target));
    keys.forEach((link) => link.classList.toggle('is-cur', link.getAttribute('href') === '#' + hit.target.dataset.spy));
  }, { rootMargin: '-40% 0px -55% 0px' });
  panes.forEach((pane) => observer.observe(pane));
})();
