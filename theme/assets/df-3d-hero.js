/* Drive Fresh — scroll-driven 3D "drive" intro.
   A dimpled golf ball sits on a tee, then launches as the visitor scrolls.
   Needs THREE (r128) loaded before this file. One instance per <df-3d-hero>. */
(function () {
  if (customElements.get('df-3d-hero')) return;

  const CREAM = 0xf6eedf;
  const SKY = 0xf1dfba;
  const GOLD = 0xe2c48a;

  const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
  const lerp = (a, b, t) => a + (b - a) * t;
  const smooth = (a, b, v) => {
    const t = clamp((v - a) / (b - a), 0, 1);
    return t * t * (3 - 2 * t);
  };

  // Bump map with hex-packed dimples on an equirectangular canvas.
  function dimpleTexture(THREE) {
    const w = 1024;
    const h = 512;
    const c = document.createElement('canvas');
    c.width = w;
    c.height = h;
    const g = c.getContext('2d');
    g.fillStyle = '#fff';
    g.fillRect(0, 0, w, h);
    const rows = 22;
    for (let r = 0; r <= rows; r++) {
      const lat = (r / rows - 0.5) * Math.PI;
      const y = (r / rows) * h;
      const ring = Math.max(1, Math.round(44 * Math.cos(lat)));
      const rx = (w / ring) * 0.36;
      const ry = (h / rows) * 0.36;
      for (let i = 0; i < ring; i++) {
        const x = ((i + (r % 2) * 0.5) / ring) * w;
        const grd = g.createRadialGradient(x, y, 0, x, y, Math.max(rx, ry));
        grd.addColorStop(0, '#6a6a6a');
        grd.addColorStop(0.7, '#bdbdbd');
        grd.addColorStop(1, '#ffffff');
        g.fillStyle = grd;
        g.beginPath();
        g.ellipse(x, y, rx, ry, 0, 0, Math.PI * 2);
        g.fill();
      }
    }
    const tex = new THREE.CanvasTexture(c);
    tex.wrapS = THREE.RepeatWrapping;
    tex.anisotropy = 4;
    return tex;
  }

  class DfHero3D extends HTMLElement {
    connectedCallback() {
      this.canvas = this.querySelector('canvas');
      this.lines = Array.from(this.querySelectorAll('[data-df-from]'));
      this.reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
      this.target = 0;
      this.progress = 0;
      this.running = false;

      if (!window.THREE || !this.canvas || !this.webglOk()) {
        this.classList.add('df3d--static');
        this.updateText(0);
        this.finishIntro();
        return;
      }
      this.build();
      this.onScroll = this.onScroll.bind(this);
      this.onResize = this.onResize.bind(this);
      this.onPointer = this.onPointer.bind(this);
      this.tick = this.tick.bind(this);
      window.addEventListener('scroll', this.onScroll, { passive: true });
      window.addEventListener('resize', this.onResize);
      window.addEventListener('pointermove', this.onPointer, { passive: true });
      this.io = new IntersectionObserver((entries) => {
        const visible = entries[0].isIntersecting && !this.reduced;
        if (visible && !this.running) {
          this.running = true;
          requestAnimationFrame(this.tick);
        }
        this.running = visible;
      });
      this.io.observe(this);
      this.onResize();
      this.onScroll();
      this.progress = this.target;
      this.classList.add('df3d--ready');
      this.finishIntro();
    }

    // Lift the intro once the scene is ready, but not before its own short
    // animation has played (about 1.1s from navigation start).
    finishIntro() {
      const loader = this.querySelector('.df3d__loader');
      if (!loader) return;
      const wait = this.reduced ? 0 : Math.max(0, 1100 - performance.now());
      setTimeout(() => {
        loader.classList.add('df3d__loader--done');
        setTimeout(() => loader.remove(), 700);
        try {
          sessionStorage.setItem('df-intro', '1');
        } catch (e) {}
      }, wait);
    }

    disconnectedCallback() {
      window.removeEventListener('scroll', this.onScroll);
      window.removeEventListener('resize', this.onResize);
      window.removeEventListener('pointermove', this.onPointer);
      if (this.io) this.io.disconnect();
      if (this.renderer) this.renderer.dispose();
    }

    webglOk() {
      try {
        const c = document.createElement('canvas');
        return !!(c.getContext('webgl') || c.getContext('experimental-webgl'));
      } catch (e) {
        return false;
      }
    }

    build() {
      const THREE = window.THREE;
      const small = window.innerWidth < 750;
      this.small = small;

      const renderer = new THREE.WebGLRenderer({ canvas: this.canvas, antialias: !small, alpha: false });
      renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, small ? 1.5 : 2));
      renderer.outputEncoding = THREE.sRGBEncoding;
      renderer.toneMapping = THREE.ACESFilmicToneMapping;
      renderer.toneMappingExposure = 1.0;
      this.renderer = renderer;

      const scene = new THREE.Scene();
      scene.background = new THREE.Color(CREAM);
      scene.fog = new THREE.Fog(CREAM, 7, 24);
      this.scene = scene;

      const camera = new THREE.PerspectiveCamera(35, 1, 0.1, 100);
      this.camera = camera;

      // Lights: warm key, cool rim, soft fill.
      scene.add(new THREE.HemisphereLight(0xfffaf0, 0xb89a72, 0.9));
      const key = new THREE.DirectionalLight(0xfff1d6, 1.5);
      key.position.set(3, 6, 4);
      if (!small) {
        renderer.shadowMap.enabled = true;
        renderer.shadowMap.type = THREE.PCFSoftShadowMap;
        key.castShadow = true;
        key.shadow.mapSize.set(1024, 1024);
        key.shadow.radius = 6;
        key.shadow.camera.near = 1;
        key.shadow.camera.far = 20;
      }
      scene.add(key);
      const rim = new THREE.DirectionalLight(GOLD, 1.1);
      rim.position.set(-4, 2, -4);
      scene.add(rim);

      // Ground: dark turf disc fading into fog.
      const ground = new THREE.Mesh(
        new THREE.CircleGeometry(30, 64),
        new THREE.MeshStandardMaterial({ color: 0xe8d9bd, roughness: 1 })
      );
      ground.rotation.x = -Math.PI / 2;
      ground.position.y = -0.62;
      ground.receiveShadow = true;
      scene.add(ground);

      // Tee.
      const tee = new THREE.Group();
      const woodMat = new THREE.MeshStandardMaterial({ color: 0xd8b98a, roughness: 0.6 });
      const cup = new THREE.Mesh(new THREE.CylinderGeometry(0.16, 0.06, 0.12, 32), woodMat);
      cup.position.y = -0.06;
      const peg = new THREE.Mesh(new THREE.CylinderGeometry(0.05, 0.015, 0.7, 24), woodMat);
      peg.position.y = -0.47;
      tee.add(cup, peg);
      tee.position.y = -0.38;
      cup.castShadow = peg.castShadow = true;
      scene.add(tee);
      this.tee = tee;

      // Ball.
      const ball = new THREE.Mesh(
        new THREE.SphereGeometry(0.42, small ? 64 : 128, small ? 48 : 96),
        new THREE.MeshStandardMaterial({
          color: 0xf7f5ef,
          roughness: 0.38,
          metalness: 0,
          bumpMap: dimpleTexture(THREE),
          bumpScale: 0.012,
        })
      );
      ball.position.y = 0.04;
      ball.castShadow = true;
      scene.add(ball);
      this.ball = ball;

      // Brass dust.
      const count = small ? 260 : 650;
      const pos = new Float32Array(count * 3);
      for (let i = 0; i < count; i++) {
        pos[i * 3] = (Math.random() - 0.5) * 16;
        pos[i * 3 + 1] = Math.random() * 14 - 1;
        pos[i * 3 + 2] = (Math.random() - 0.5) * 16;
      }
      const dustGeo = new THREE.BufferGeometry();
      dustGeo.setAttribute('position', new THREE.BufferAttribute(pos, 3));
      const dust = new THREE.Points(
        dustGeo,
        new THREE.PointsMaterial({
          color: 0xb8925a,
          size: small ? 0.035 : 0.028,
          transparent: true,
          opacity: 0.6,
          depthWrite: false,
        })
      );
      scene.add(dust);
      this.dust = dust;

      this.pointer = { x: 0, y: 0, sx: 0, sy: 0 };
      this.skyFrom = new THREE.Color(CREAM);
      this.skyTo = new THREE.Color(SKY);
      this.clock = new THREE.Clock();
    }

    onResize() {
      if (!this.renderer) return;
      const w = this.clientWidth;
      const h = window.innerHeight;
      this.renderer.setSize(w, h, false);
      this.camera.aspect = w / h;
      this.camera.fov = w < 750 ? 48 : 35;
      this.camera.updateProjectionMatrix();
      if (this.reduced) this.render(0, 0);
    }

    onScroll() {
      const r = this.getBoundingClientRect();
      const span = Math.max(1, r.height - window.innerHeight);
      this.target = clamp(-r.top / span, 0, 1);
      if (this.reduced && this.renderer) {
        // No animation loop for reduced motion: jump straight to the scroll position.
        this.progress = this.target;
        this.render(this.progress, 0);
        this.updateText(this.progress);
      }
    }

    onPointer(e) {
      this.pointer.x = (e.clientX / window.innerWidth) * 2 - 1;
      this.pointer.y = (e.clientY / window.innerHeight) * 2 - 1;
    }

    tick() {
      if (!this.running) return;
      const dt = Math.min(this.clock.getDelta(), 0.05);
      // Ease toward the scroll target for a weighted, cinematic feel.
      this.progress = lerp(this.progress, this.target, 1 - Math.pow(0.0008, dt));
      this.pointer.sx = lerp(this.pointer.sx, this.pointer.x, 0.05);
      this.pointer.sy = lerp(this.pointer.sy, this.pointer.y, 0.05);
      this.render(this.progress, this.clock.elapsedTime);
      this.updateText(this.progress);
      requestAnimationFrame(this.tick);
    }

    render(p, t) {
      const THREE = window.THREE;
      const launch = smooth(0.18, 0.85, p);
      const idle = 1 - smooth(0.1, 0.25, p);

      // Ball flight: up and away along a gentle arc, spinning hard.
      const ball = this.ball;
      ball.position.set(launch * (this.small ? 1.4 : 5.5), 0.04 + launch * 8.5 + Math.sin(t * 1.4) * 0.02 * idle, -launch * 10);
      ball.rotation.x = t * 0.25 + launch * 28;
      ball.rotation.y = t * 0.15;

      // Tee wobbles once as the ball leaves it.
      this.tee.rotation.z = Math.sin(clamp((p - 0.18) * 30, 0, Math.PI)) * 0.12 * (1 - smooth(0.25, 0.4, p));

      // Camera: low and close on the tee, then tilts up and follows into the sky.
      const cam = this.camera;
      const orbit = t * 0.06 * idle;
      cam.position.set(
        Math.sin(orbit) * 4.2 + this.pointer.sx * 0.25,
        0.35 + launch * 4.5 - this.pointer.sy * 0.15,
        Math.cos(orbit) * 4.2 - launch * 3
      );
      // Aim above the ball at rest so it sits low in frame under the headline;
      // in flight, trail it so it drifts up and out of the top-right corner.
      const look = new THREE.Vector3(
        ball.position.x * 0.12,
        0.42 * (1 - launch) + ball.position.y * 0.72,
        ball.position.z * 0.6
      );
      cam.lookAt(look);

      // Sky lifts from deep pine as the ball climbs.
      this.scene.background.copy(this.skyFrom).lerp(this.skyTo, launch);
      this.scene.fog.color.copy(this.scene.background);

      // Dust drifts and streaks downward past the camera during launch.
      this.dust.rotation.y = t * 0.02;
      this.dust.position.y = -launch * 6;

      this.renderer.render(this.scene, cam);
    }

    updateText(p) {
      this.lines.forEach((el) => {
        const from = parseFloat(el.dataset.dfFrom);
        const to = parseFloat(el.dataset.dfTo);
        const fadeIn = from === 0 ? 1 : smooth(from, from + 0.08, p);
        const fadeOut = to >= 1 ? 1 : 1 - smooth(to - 0.08, to, p);
        const o = Math.min(fadeIn, fadeOut);
        el.style.opacity = o.toFixed(3);
        el.style.transform = `translate3d(0, ${((1 - fadeIn) * 24 - (1 - fadeOut) * 24).toFixed(1)}px, 0)`;
        el.style.filter = o < 0.98 ? `blur(${((1 - o) * 6).toFixed(1)}px)` : 'none';
        el.style.pointerEvents = o > 0.5 ? 'auto' : 'none';
      });
      const hint = this.querySelector('.df3d__hint');
      if (hint) hint.style.opacity = (1 - smooth(0.02, 0.1, p)).toFixed(3);
    }
  }

  customElements.define('df-3d-hero', DfHero3D);
})();
