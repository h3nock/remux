const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)');

// A pause button shows what its video is doing, from the video's own events, so a play the browser refuses (Low
// Power Mode) shows play.
const bindPauseButton = (video, button) => {
  const show = () => {
    button.classList.toggle('is-paused', video.paused);
    button.setAttribute('aria-label', video.paused ? 'Play the recording' : 'Pause the recording');
  };
  video.addEventListener('play', show);
  video.addEventListener('pause', show);
  return show;
};

// Section keys: a click, or the key's digit, scrolls to the section and marks it current.
(() => {
  const sections = [...document.querySelectorAll('.keys [data-key]')]
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
  // The address names the pick, on load and after Back or Forward, as it does after a key.
  const fromHash = () => sections.find((s) => s.link.getAttribute('href') === location.hash) || null;
  addEventListener('popstate', () => { picked = fromHash(); schedule(); });
  // A pick leaves its section at the top of the window, below the top line, or, for a section that can't scroll up
  // that far, the page at its end with the section still below the line. A scroll that ends anywhere else, as after
  // dragging the scrollbar, was the reader's, and the position decides again.
  addEventListener('scrollend', () => {
    if (!picked) return;
    const root = document.documentElement;
    const line = parseFloat(getComputedStyle(root).scrollPaddingTop) + parseFloat(getComputedStyle(picked.target).scrollMarginTop);
    const top = picked.target.getBoundingClientRect().top;
    const atEnd = innerHeight + scrollY >= root.scrollHeight - 2;
    if (Math.abs(top - line) > 2 && !(atEnd && top > line)) release();
  });

  for (const section of sections) {
    section.link.addEventListener('click', (event) => { event.preventDefault(); go(section); });
  }
  addEventListener('keydown', (event) => {
    if (event.metaKey || event.ctrlKey || event.altKey || document.querySelector('.viewer[open]')) return;
    if (/input|textarea|select/i.test(event.target.tagName)) return;
    const section = sections.find((s) => s.link.dataset.key === event.key);
    if (section) { event.preventDefault(); go(section); return; }
    if (/^(Arrow(Up|Down)|Page(Up|Down)|Home|End| )$/.test(event.key)) release();
  });
  for (const type of ['wheel', 'touchstart']) addEventListener(type, release, { passive: true });
  addEventListener('scroll', schedule, { passive: true });
  addEventListener('resize', schedule);

  picked = fromHash();
  update();
})();

// The opening's recording plays only while it's on screen, never on its own when Reduce Motion is on, and can be
// paused. While the viewer shows it full size, it is held still.
const recording = (() => {
  const video = document.querySelector('.loop video');
  const button = document.querySelector('.loop-toggle');
  let paused = reduceMotion.matches;
  let visible = false;
  let held = false;
  const show = bindPauseButton(video, button);
  const sync = () => {
    if (!paused && visible && !held) video.play().catch(show); else video.pause();
  };
  // The button acts on what the video is doing, so the first press plays it after a browser refused to, and it plays
  // or pauses wherever the video is on the page; scrolling the video away still pauses it.
  button.addEventListener('click', () => {
    paused = !video.paused;
    if (paused) video.pause(); else video.play().catch(show);
  });
  // Turning Reduce Motion on stops the loop; turning it off leaves it to the visitor.
  reduceMotion.addEventListener('change', () => { if (reduceMotion.matches) { paused = true; sync(); } });
  new IntersectionObserver(([entry]) => { visible = entry.isIntersecting && entry.intersectionRatio >= 0.25; sync(); },
    { threshold: [0, 0.25] }).observe(video);
  show();
  sync();
  return {
    // Hold still and say where it was and whether it was playing.
    hold() {
      held = true;
      const state = { at: video.currentTime, playing: !video.paused };
      video.pause();
      return state;
    },
    // Pick up from a moment, playing again if it was playing when held.
    release(at, playing) {
      held = false;
      video.currentTime = at;
      if (playing) { paused = false; sync(); }
    },
  };
})();

// The viewer shows a screen, or the recording, full size. A screen opens at the largest size its image offers; the
// recording continues from the moment the small one was at, and the small one picks up from where it stopped.
(() => {
  const viewer = document.querySelector('.viewer');
  const image = viewer.querySelector('img');
  const film = viewer.querySelector('video');
  const filmButton = viewer.querySelector('.viewer-toggle');
  const open = (kind, label) => {
    viewer.dataset.kind = kind;
    viewer.setAttribute('aria-label', label);
    viewer.showModal();
  };

  for (const zoom of document.querySelectorAll('.zoom')) {
    zoom.addEventListener('click', () => {
      const img = zoom.querySelector('img');
      const largest = img.srcset ? img.srcset.split(',').pop().trim().split(' ')[0] : '';
      image.src = largest || img.currentSrc || img.src;
      image.alt = img.alt;
      zoom.focus({ preventScroll: true });
      open('image', 'Screen, full size');
    });
  }

  const showFilm = bindPauseButton(film, filmButton);
  filmButton.addEventListener('click', () => { if (film.paused) film.play().catch(showFilm); else film.pause(); });
  let resume = false;
  const openFilm = () => {
    const { at, playing } = recording.hold();
    resume = playing;
    const start = () => {
      film.currentTime = at;
      if (reduceMotion.matches) showFilm(); else film.play().catch(showFilm);
    };
    if (film.readyState >= 1) start();
    else { film.addEventListener('loadedmetadata', start, { once: true }); film.load(); }
    open('video', 'Recording, full size');
  };
  document.querySelector('.loop .screen').addEventListener('click', openFilm);
  document.querySelector('.demo-enlarge').addEventListener('click', openFilm);

  viewer.addEventListener('close', () => {
    if (viewer.dataset.kind !== 'video') return;
    film.pause();
    recording.release(film.currentTime, resume);
  });
  viewer.querySelector('.close').addEventListener('click', () => viewer.close());
  viewer.addEventListener('click', (event) => { if (event.target === viewer) viewer.close(); });
})();

// On a computer the TestFlight button opens a code to scan with an iPhone, since the link itself lands on Apple's
// page, which only says to open it on an iPhone. Touch screens follow the link.
(() => {
  const panel = document.querySelector('.scan-panel');
  const buttons = [...document.querySelectorAll('a.btn[href^="https://testflight.apple.com/"]')];
  if (!panel || !buttons.length) return;
  const computer = matchMedia('(hover: hover) and (pointer: fine)');
  let owner = null;

  // Under the button, at its left edge; above it when there isn't room below.
  const place = (button) => {
    const r = button.getBoundingClientRect();
    const gap = 8;
    const below = innerHeight - r.bottom >= panel.offsetHeight + gap || r.top < panel.offsetHeight + gap;
    panel.style.top = `${(below ? r.bottom + gap : r.top - gap - panel.offsetHeight) + scrollY}px`;
    panel.style.left = `${Math.min(r.left, document.documentElement.clientWidth - panel.offsetWidth - 16) + scrollX}px`;
  };
  const hide = () => {
    panel.hidden = true;
    owner?.setAttribute('aria-expanded', 'false');
    owner = null;
  };
  const show = (button) => {
    hide();
    owner = button;
    panel.hidden = false;
    place(button);
    button.setAttribute('aria-expanded', 'true');
    panel.focus({ preventScroll: true });
  };
  const hideAndReturn = () => { const button = owner; hide(); button.focus(); };

  for (const button of buttons) {
    button.setAttribute('aria-haspopup', 'dialog');
    button.setAttribute('aria-expanded', 'false');
    button.addEventListener('click', (event) => {
      if (!computer.matches) return;
      event.preventDefault();
      if (owner === button) hideAndReturn(); else show(button);
    });
  }
  addEventListener('keydown', (event) => { if (event.key === 'Escape' && owner) hideAndReturn(); });
  addEventListener('pointerdown', (event) => {
    if (owner && !panel.contains(event.target) && !owner.contains(event.target)) hide();
  });
  addEventListener('resize', () => { if (owner) place(owner); });
  // Using the panel's link is the panel's job done, and a page brought back from history starts with it closed, as
  // it was before it was opened.
  panel.querySelector('a').addEventListener('click', hide);
  addEventListener('pageshow', (event) => { if (event.persisted) hide(); });
})();
