/* Drive Fresh — light scroll motion for df-* sections. No dependencies.
   [data-df-split]  heading words rise into place when it scrolls into view
   [data-df-reveal] gets .df-in once it scrolls into view (CSS does the rest)
   [data-df-scrub]  gets --df-p from 0 to 1 while its top travels up the screen
   df-marquee       scrolling type that speeds up and reverses with the scroll
   Reduced motion: everything is shown in its final state. */
(() => {
  if (window.DfMotion) return;

  const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  document.documentElement.classList.add('df-motion');
  if (reduced) document.documentElement.classList.add('df-motion--reduced');

  // Wrap each word of a heading in a mask so it can slide up from below.
  // Only text nodes are split; inline elements (em, a) stay intact.
  function split(el) {
    if (el.dataset.dfSplitDone) return;
    el.dataset.dfSplitDone = '1';
    let i = 0;
    const walk = (node) => {
      Array.from(node.childNodes).forEach((child) => {
        if (child.nodeType === 3) {
          const frag = document.createDocumentFragment();
          child.textContent.split(/(\s+)/).forEach((part) => {
            if (!part) return;
            if (/^\s+$/.test(part)) {
              frag.appendChild(document.createTextNode(part));
              return;
            }
            const mask = document.createElement('span');
            mask.className = 'df-w';
            const inner = document.createElement('span');
            inner.className = 'df-w__i';
            inner.style.setProperty('--i', i++);
            inner.textContent = part;
            mask.appendChild(inner);
            frag.appendChild(mask);
          });
          child.replaceWith(frag);
        } else if (child.nodeType === 1) {
          walk(child);
        }
      });
    };
    walk(el);
  }

  const revealIO = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        entry.target.classList.add('df-in');
        revealIO.unobserve(entry.target);
      });
    },
    { rootMargin: '0px 0px -12% 0px' }
  );

  // Scrubbed elements only listen while on screen.
  const scrubbing = new Set();
  const scrubIO = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (entry.isIntersecting) scrubbing.add(entry.target);
      else scrubbing.delete(entry.target);
    });
    requestFrame();
  });

  function updateScrub() {
    const vh = window.innerHeight;
    scrubbing.forEach((el) => {
      const top = el.getBoundingClientRect().top;
      // 0 when the top edge enters at the bottom, 1 once it reaches 25% from the top.
      const p = Math.min(1, Math.max(0, (vh - top) / (vh * 0.75)));
      el.style.setProperty('--df-p', p.toFixed(4));
    });
  }

  // Marquees: base speed comes from CSS; scrolling adds speed and direction.
  const marquees = new Set();
  const marqueeIO = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      const anim = entry.target._dfAnim;
      if (!anim) return;
      if (entry.isIntersecting) {
        marquees.add(entry.target);
        anim.play();
      } else {
        marquees.delete(entry.target);
        anim.pause();
      }
    });
  });

  let lastY = window.scrollY;
  let velocity = 0;
  let direction = 1;
  let frame = 0;

  function requestFrame() {
    if (!frame) frame = requestAnimationFrame(onFrame);
  }

  function onFrame() {
    frame = 0;
    updateScrub();
    const y = window.scrollY;
    const dy = y - lastY;
    lastY = y;
    if (dy !== 0) direction = dy > 0 ? 1 : -1;
    velocity += (Math.min(Math.abs(dy), 80) - velocity) * 0.12;
    marquees.forEach((el) => {
      if (el._dfAnim) el._dfAnim.playbackRate = direction * (1 + velocity * 0.12);
    });
    // Keep easing back to base speed after scrolling stops.
    if (velocity > 0.05 && marquees.size) requestFrame();
  }

  function init(scope) {
    scope.querySelectorAll('[data-df-split]').forEach((el) => {
      split(el);
      if (reduced) el.classList.add('df-in');
      else revealIO.observe(el);
    });
    scope.querySelectorAll('[data-df-reveal]').forEach((el) => {
      if (reduced) el.classList.add('df-in');
      else revealIO.observe(el);
    });
    scope.querySelectorAll('[data-df-scrub]').forEach((el) => {
      if (reduced) el.style.setProperty('--df-p', 1);
      else scrubIO.observe(el);
    });
    if (!reduced) {
      scope.querySelectorAll('.df-marquee__track').forEach((track) => {
        if (track._dfAnim || !track.getAnimations) return;
        track._dfAnim = track.getAnimations()[0];
        if (track._dfAnim) marqueeIO.observe(track);
      });
    }
    updateScrub();
  }

  window.addEventListener('scroll', requestFrame, { passive: true });
  window.addEventListener('resize', requestFrame);
  document.addEventListener('shopify:section:load', (event) => init(event.target));

  window.DfMotion = { init };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => init(document));
  else init(document);
})();
