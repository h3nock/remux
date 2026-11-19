(() => {
  const links = [...document.querySelectorAll('.keys [data-key]')];
  const sections = links
    .map((link) => ({ link, target: document.querySelector(link.getAttribute('href')) }))
    .filter((section) => section.target);
  if (!sections.length) return;

  // A section picked from the keys stays current until the reader scrolls by hand: the last sections can't reach
  // the top of the window, so their position alone can't tell which one was picked.
  let picked = null;
  let frame = 0;

  const current = () => {
    if (picked) return picked;
    const root = document.documentElement;
    if (scrollY > 0 && innerHeight + scrollY >= root.scrollHeight - 2) return sections[sections.length - 1];
    const line = innerHeight * 0.3;
    let found = null;
    for (const section of sections) {
      if (section.target.getBoundingClientRect().top <= line) found = section;
    }
    return found;
  };

  const update = () => {
    frame = 0;
    const now = current();
    for (const section of sections) {
      const on = section === now;
      section.link.classList.toggle('is-cur', on);
      if (on) section.link.setAttribute('aria-current', 'location');
      else section.link.removeAttribute('aria-current');
    }
  };
  const schedule = () => { if (!frame) frame = requestAnimationFrame(update); };

  const go = (section) => {
    picked = section;
    const hash = section.link.getAttribute('href');
    if (location.hash !== hash) history.pushState(null, '', hash);
    section.target.scrollIntoView();
    // Keyboard focus moves with the reader, so Tab continues inside the section rather than back in the top line.
    if (!section.target.hasAttribute('tabindex')) section.target.setAttribute('tabindex', '-1');
    section.target.focus({ preventScroll: true });
    update();
  };
  const release = () => { if (picked) { picked = null; schedule(); } };
  addEventListener('popstate', release);

  for (const section of sections) {
    section.link.addEventListener('click', (event) => { event.preventDefault(); go(section); });
  }
  addEventListener('keydown', (event) => {
    if (event.metaKey || event.ctrlKey || event.altKey) return;
    if (/input|textarea|select/i.test(event.target.tagName)) return;
    const section = sections.find((s) => s.link.dataset.key === event.key);
    if (section) { event.preventDefault(); go(section); return; }
    if (/^(Arrow(Up|Down)|Page(Up|Down)|Home|End| )$/.test(event.key)) release();
  });
  for (const type of ['wheel', 'touchstart']) addEventListener(type, release, { passive: true });
  addEventListener('scroll', schedule, { passive: true });
  addEventListener('resize', schedule);

  picked = sections.find((s) => s.link.getAttribute('href') === location.hash) || null;
  update();
})();

// Screen strips: on a narrow pane a section's screens scroll sideways; the count and previous/next follow the strip.
(() => {
  const reduce = matchMedia('(prefers-reduced-motion: reduce)');
  for (const wrap of document.querySelectorAll('.strip-wrap')) {
    const strip = wrap.querySelector('.pair');
    const items = [...strip.children];
    const last = items.length - 1;
    const prev = wrap.querySelector('.prev');
    const next = wrap.querySelector('.next');
    const count = wrap.querySelector('.count .n');
    const label = wrap.querySelector('.count .label');
    // The screen in view: the one nearest the strip's left edge, or the last once the strip can't scroll further.
    const current = () => {
      if (strip.scrollLeft + strip.clientWidth >= strip.scrollWidth - 2) return last;
      const step = items[1].offsetLeft - items[0].offsetLeft;
      return step > 0 ? Math.max(0, Math.min(last, Math.round(strip.scrollLeft / step))) : 0;
    };
    const go = (i) => strip.scrollTo({ left: items[i].offsetLeft - items[0].offsetLeft, behavior: reduce.matches ? 'auto' : 'smooth' });
    let frame = 0;
    const update = () => {
      frame = 0;
      const i = current();
      prev.disabled = i === 0;
      next.disabled = i === last;
      count.textContent = String(i + 1);
      label.textContent = items[i].querySelector('figcaption').textContent;
    };
    strip.addEventListener('scroll', () => { if (!frame) frame = requestAnimationFrame(update); }, { passive: true });
    // A screen that takes keyboard focus scrolls fully into view, and the count follows.
    strip.addEventListener('focusin', (event) => {
      const i = items.findIndex((item) => item.contains(event.target));
      if (i >= 0 && strip.scrollWidth > strip.clientWidth) go(i);
    });
    addEventListener('resize', update);
    prev.addEventListener('click', () => go(Math.max(0, current() - 1)));
    next.addEventListener('click', () => go(Math.min(last, current() + 1)));
    update();
  }
})();

// Tap a screen to see it whole, full size.
(() => {
  const viewer = document.querySelector('.viewer');
  const big = viewer.querySelector('img');
  for (const zoom of document.querySelectorAll('.zoom')) {
    zoom.addEventListener('click', () => {
      const img = zoom.querySelector('img');
      // the viewer shows the screen up to 520px wide: open the largest size the image offers
      const largest = img.srcset ? img.srcset.split(',').pop().trim().split(' ')[0] : '';
      big.src = largest || img.currentSrc || img.src;
      big.alt = img.alt;
      viewer.showModal();
    });
  }
  viewer.querySelector('.close').addEventListener('click', () => viewer.close());
  viewer.addEventListener('click', (event) => { if (event.target === viewer) viewer.close(); });
})();

// The opening's loop plays only while it's on screen, never on its own when reduced motion is on, and can be paused.
(() => {
  const video = document.querySelector('.loop video');
  const toggle = document.querySelector('.loop-toggle');
  if (!video || !toggle) return;
  const reduce = matchMedia('(prefers-reduced-motion: reduce)');
  let paused = reduce.matches;
  let visible = false;
  // The button shows what the video is doing, from its own events, so a refused play (Low Power Mode) shows play.
  const show = () => {
    toggle.classList.toggle('is-paused', video.paused);
    toggle.setAttribute('aria-label', video.paused ? 'Play the recording' : 'Pause the recording');
  };
  video.addEventListener('play', show);
  video.addEventListener('pause', show);
  const sync = () => {
    if (!paused && visible) video.play().catch(show); else video.pause();
  };
  // the button acts on what the video is doing, so when a browser refused to start it, the first tap plays it
  toggle.addEventListener('click', () => { paused = !video.paused; sync(); });
  // Turning Reduce Motion on stops the loop; turning it off leaves it to the visitor.
  reduce.addEventListener('change', () => { if (reduce.matches) { paused = true; sync(); } });
  new IntersectionObserver(([entry]) => { visible = entry.isIntersecting && entry.intersectionRatio >= 0.25; sync(); }, { threshold: 0.25 }).observe(video);
  show();
  sync();
})();
