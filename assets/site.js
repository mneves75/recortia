// Recortia landing: video autoplay (respecting reduced motion), sound toggle, before/after slider, copy button, reveals.
(() => {
  'use strict';
  document.documentElement.classList.add('js');
  const reduce = window.matchMedia('(prefers-reduced-motion: reduce)');

  // ---- hero video: muted autoplay only when motion is welcome; native controls otherwise
  const video = document.querySelector('.player video');
  const sound = document.querySelector('.player .sound');
  if (video && sound) {
    const label = sound.querySelector('span');
    const setSound = on => {
      video.muted = !on;
      sound.setAttribute('aria-pressed', String(on));
      label.textContent = on ? sound.dataset.off : sound.dataset.on;
    };
    const start = () => {
      video.controls = false;
      sound.hidden = false;
      const p = video.play();
      if (p) p.catch(() => { video.controls = true; sound.hidden = true; });
    };
    if (!reduce.matches) start();
    sound.addEventListener('click', () => {
      setSound(video.muted);
      if (video.paused) video.play().catch(() => {});
    });
    // pause while scrolled away, resume when back (autoplay mode only)
    if ('IntersectionObserver' in window) {
      new IntersectionObserver(([en]) => {
        if (reduce.matches || video.controls) return;
        if (en.isIntersecting) video.play().catch(() => {}); else video.pause();
      }, { threshold: 0.2 }).observe(video);
    }
  }

  // ---- before/after comparison
  const cmp = document.querySelector('.compare');
  if (cmp) {
    const range = cmp.querySelector('.compare-range');
    let touched = false, raf = 0;
    const set = v => cmp.style.setProperty('--v', v + '%');
    const stopDemo = () => { touched = true; cancelAnimationFrame(raf); };
    range.addEventListener('input', () => { stopDemo(); set(range.value); });
    range.addEventListener('focus', stopDemo);
    range.addEventListener('pointerdown', stopDemo);
    set(range.value);
    // one demonstration sweep when the section first comes into view
    if (!reduce.matches && 'IntersectionObserver' in window) {
      const io = new IntersectionObserver(([en]) => {
        if (!en.isIntersecting) return;
        io.disconnect();
        if (touched) return;
        const keys = [[0, 50], [700, 84], [1500, 18], [2200, 50]], t0 = performance.now();
        const ease = u => (u < .5 ? 4 * u * u * u : 1 - Math.pow(-2 * u + 2, 3) / 2);
        const step = now => {
          if (touched) return;
          const t = now - t0; let k = 1;
          while (k < keys.length - 1 && t > keys[k][0]) k++;
          const [a, va] = keys[k - 1], [b, vb] = keys[k];
          const u = Math.min(1, Math.max(0, (t - a) / (b - a)));
          const v = Math.round(va + (vb - va) * ease(u));
          range.value = v; set(v);
          if (t < keys[keys.length - 1][0]) raf = requestAnimationFrame(step);
        };
        raf = requestAnimationFrame(step);
      }, { threshold: 0.6 });
      io.observe(cmp);
    }
  }

  // ---- copy the install command
  const copy = document.querySelector('button.copy');
  if (copy) {
    const label = copy.querySelector('span');
    let timer = 0;
    copy.addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(copy.dataset.cmd);
        copy.classList.add('done'); label.textContent = copy.dataset.copied;
        clearTimeout(timer);
        timer = setTimeout(() => { copy.classList.remove('done'); label.textContent = copy.dataset.copy; }, 2200);
      } catch {
        // no clipboard access: select the command so the viewer can copy it
        const sel = window.getSelection(), r = document.createRange();
        r.selectNodeContents(copy.parentElement.querySelector('code')); sel.removeAllRanges(); sel.addRange(r);
      }
    });
  }

  // ---- reveal on scroll
  const items = document.querySelectorAll('[data-reveal]');
  if ('IntersectionObserver' in window) {
    const io = new IntersectionObserver(ens => ens.forEach(en => { if (en.isIntersecting) { en.target.classList.add('in'); io.unobserve(en.target); } }), { rootMargin: '0px 0px -8% 0px' });
    items.forEach(i => io.observe(i));
  } else items.forEach(i => i.classList.add('in'));
})();
