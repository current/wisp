// Wisp landing page motion. Everything is visible without this file;
// it only adds motion when the visitor allows it.
(function () {
  var root = document.documentElement;

  function giveUp() {
    root.classList.remove('motion', 'anim');
  }

  if (!window.gsap || !window.ScrollTrigger) { giveUp(); return; }
  gsap.registerPlugin(ScrollTrigger);

  var mm = gsap.matchMedia();
  var EASE = 'power3.out';

  // ---------- Pinned tour on large screens ----------
  mm.add('(prefers-reduced-motion: no-preference) and (min-width: 900px) and (min-height: 640px)', function () {
    root.classList.add('motion');

    var stage = document.querySelector('.stage');
    var caps = gsap.utils.toArray('.cap');
    var buttons = gsap.utils.toArray('.seg button');

    // 1. The window rises out of the backdrop and settles flat as the tour arrives.
    gsap.fromTo(stage,
      { rotateX: 18, scale: 0.9, y: 40, transformOrigin: '50% 100%' },
      { rotateX: 0, scale: 1, y: 0, ease: 'none',
        scrollTrigger: { trigger: '.tour-pin', start: 'top bottom', end: 'top top', scrub: 0.6 } });

    // 2. Pin and step: Overview -> inside an app -> menu bar.
    gsap.set(caps, { autoAlpha: 1 });
    gsap.set(caps.slice(1), { opacity: 0, y: 14 });
    gsap.set('.win-drawer', { autoAlpha: 0 });
    gsap.set('.menubar', { autoAlpha: 0, y: -6 });
    gsap.set('.popover', { autoAlpha: 0, y: -18, scale: 0.94, transformOrigin: '80% 0%' });

    var tl = gsap.timeline({ defaults: { ease: 'power2.inOut' } });
    tl.addLabel('s0', 0)
      .to(caps[0], { opacity: 0, y: -14, duration: 0.4 }, 0.6)
      .to('.win-drawer', { autoAlpha: 1, duration: 0.6 }, 0.6)
      .fromTo('.win-drawer', { x: 24 }, { x: 0, duration: 0.6, ease: 'power3.out' }, 0.6)
      .to(caps[1], { opacity: 1, y: 0, duration: 0.4 }, 0.9)
      .addLabel('s1', 1.6)
      .to(caps[1], { opacity: 0, y: -14, duration: 0.4 }, 2.2)
      .set('.win-base', { autoAlpha: 0 }, 2.19)
      .to('.win-drawer', { scale: 0.97, opacity: 0.5, duration: 0.6 }, 2.2)
      .to('.menubar', { autoAlpha: 1, y: 0, duration: 0.4 }, 2.3)
      .to('.popover', { autoAlpha: 1, y: 0, scale: 1, duration: 0.6, ease: 'power3.out' }, 2.5)
      .to(caps[2], { opacity: 1, y: 0, duration: 0.4 }, 2.5)
      .addLabel('s2', 3.2)
      .to({}, { duration: 0.4 });

    var labels = [0, 1.6, 3.2];
    var current = -1;
    function setStep(i) {
      if (i === current) return;
      current = i;
      buttons.forEach(function (b, j) { b.setAttribute('aria-current', j === i ? 'true' : 'false'); });
    }
    setStep(0);

    var st = ScrollTrigger.create({
      animation: tl,
      trigger: '.tour-pin',
      start: 'top top',
      end: '+=220%',
      pin: true,
      scrub: 0.5,
      snap: { snapTo: 'labels', directional: false, inertia: false, duration: { min: 0.25, max: 0.7 }, delay: 0.15, ease: 'power2.inOut' },
      onUpdate: function () {
        var t = tl.time();
        setStep(t < 0.95 ? 0 : t < 2.55 ? 1 : 2);
      }
    });

    function onClick(e) {
      var i = Number(e.currentTarget.dataset.step);
      var y = st.start + (st.end - st.start) * (labels[i] / tl.duration());
      window.scrollTo({ top: Math.round(y) + 1, behavior: 'smooth' });
    }
    buttons.forEach(function (b) { b.addEventListener('click', onClick); });

    return function () {
      buttons.forEach(function (b) { b.removeEventListener('click', onClick); });
      root.classList.remove('motion');
    };
  });

  // ---------- Motion for every width ----------
  mm.add('(prefers-reduced-motion: no-preference)', function () {
    root.classList.add('anim');

    // Hero: the copy settles in once, fast.
    gsap.fromTo('.hero > *',
      { y: 18, opacity: 0 },
      { y: 0, opacity: 1, duration: 0.8, ease: EASE, stagger: 0.06, delay: 0.05 });

    // Performance: cards rise, bars grow from zero, figures count up.
    gsap.fromTo('.perf-card',
      { y: 32, opacity: 0 },
      { y: 0, opacity: 1, duration: 0.8, ease: EASE, stagger: 0.1,
        scrollTrigger: { trigger: '.perf-grid', start: 'top 85%', once: true } });

    gsap.utils.toArray('.perf-card').forEach(function (card, i) {
      var fills = card.querySelectorAll('.fill');
      gsap.fromTo(fills, { scaleX: 0 }, {
        scaleX: 1, duration: 1.1, ease: 'expo.out', stagger: 0.08, delay: 0.25 + i * 0.1,
        scrollTrigger: { trigger: card, start: 'top 80%', once: true }
      });
      card.querySelectorAll('[data-count]').forEach(function (el) {
        var to = parseFloat(el.dataset.count);
        var dec = parseInt(el.dataset.dec || '0', 10);
        var obj = { v: 0 };
        el.textContent = (0).toFixed(dec);
        gsap.to(obj, {
          v: to, duration: 1.2, ease: 'power2.out', delay: 0.2 + i * 0.1,
          scrollTrigger: { trigger: card, start: 'top 80%', once: true },
          onUpdate: function () { el.textContent = obj.v.toFixed(dec); }
        });
      });
    });

    // Feature cards cascade in by row as they arrive.
    gsap.set('.feat', { y: 28, opacity: 0 });
    ScrollTrigger.batch('.feat', {
      start: 'top 90%',
      once: true,
      onEnter: function (batch) {
        gsap.to(batch, { y: 0, opacity: 1, duration: 0.7, ease: EASE, stagger: 0.07, overwrite: true });
      }
    });

    // Hover cards: a single tinted plate follows the pointer from card to card.
    var grid = document.querySelector('.feat-grid');
    var cleanupPlate = null;
    if (grid && matchMedia('(hover: hover)').matches) {
      var plate = document.createElement('div');
      plate.className = 'plate';
      plate.setAttribute('aria-hidden', 'true');
      grid.prepend(plate);
      var cards = gsap.utils.toArray('.feat', grid);
      var shown = false;
      var enter = function (e) {
        var c = e.currentTarget;
        cards.forEach(function (x) { x.classList.toggle('is-active', x === c); });
        var to = {
          x: c.offsetLeft, y: c.offsetTop, width: c.offsetWidth, height: c.offsetHeight,
          backgroundColor: getComputedStyle(c).getPropertyValue('--tint').trim()
        };
        if (!shown) {
          gsap.set(plate, to);
          gsap.to(plate, { autoAlpha: 1, duration: 0.2, overwrite: 'auto' });
          shown = true;
        } else {
          gsap.to(plate, Object.assign({ autoAlpha: 1, duration: 0.45, ease: 'power3.out', overwrite: 'auto' }, to));
        }
      };
      var leave = function () {
        cards.forEach(function (x) { x.classList.remove('is-active'); });
        gsap.to(plate, { autoAlpha: 0, duration: 0.25, overwrite: 'auto' });
        shown = false;
      };
      cards.forEach(function (c) { c.addEventListener('pointerenter', enter); });
      grid.addEventListener('pointerleave', leave);
      cleanupPlate = function () {
        cards.forEach(function (c) { c.removeEventListener('pointerenter', enter); c.classList.remove('is-active'); });
        grid.removeEventListener('pointerleave', leave);
        plate.remove();
      };
    }

    // Download: the icon lands, then the copy follows.
    gsap.fromTo('.download > *',
      { y: 20, opacity: 0 },
      { y: 0, opacity: 1, duration: 0.7, ease: EASE, stagger: 0.06,
        scrollTrigger: { trigger: '.download', start: 'top 75%', once: true } });

    // Static tour (phones, tablets, short windows): each step fades up on its own.
    if (!root.classList.contains('motion')) {
      gsap.utils.toArray('.cap').forEach(function (cap) {
        gsap.fromTo(cap, { y: 24, opacity: 0 }, {
          y: 0, opacity: 1, duration: 0.7, ease: EASE,
          scrollTrigger: { trigger: cap, start: 'top 88%', once: true }
        });
      });
      gsap.fromTo('.win-base', { y: 40, scale: 0.96, opacity: 0 }, {
        y: 0, scale: 1, opacity: 1, duration: 1, ease: EASE, delay: 0.25
      });
    }

    return function () { if (cleanupPlate) cleanupPlate(); root.classList.remove('anim'); };
  });

  // Lazy images change heights; keep trigger positions honest.
  window.addEventListener('load', function () { ScrollTrigger.refresh(); });
})();
