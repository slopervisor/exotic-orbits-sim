# Exotic Orbits Sim — Design Document

- **Date:** 2026-11-22
- **Status:** Approved in principle (design review 2026-11-22); pending spec review before implementation
- **Author:** Hermes (agent) for Maciej Makowski
- **Repo location (local):** `/workspace/exotic-orbits-sim`

---

## 1. Purpose

An interactive, visually attractive demonstration of **few-body gravitational dynamics** outside the
ordinary Solar System. It shows exotic initial configurations whose behaviour is either rarely seen
or educationally revealing (chaos, marginal stability, relativistic perihelion precession), lets the
user modify the initial conditions live, and documents every calculation behind it.

Deliverables:

1. A runnable web app built from **Rust → WebAssembly**, driving **raw WebGL2** from hand-written
   host JavaScript (`HTML`). Zero external crates on the Rust side.
2. `PHYSICS.md` documenting the Newtonian and post-Newtonian mechanics, the integrator, the units,
   and the rendering pipeline.
3. A one-command deployment path to a public **GitHub Pages** site.

---

## 2. Success Criteria (acceptance)

| # | Criterion | How verified |
|---|-----------|--------------|
| 1 | App loads over HTTP and renders ≥ 50 fps at native resolution on a typical laptop GPU | Headless browser capture + `requestAnimationFrame` timing |
| 2 | Every preset integrates stably for ≥ 500 closed orbits at nominal time scale with no blow-ups, tunneling, or unphysical captures | Long-run offline Rust test harness printing min/max separation + energy drift |
| 3 | 1PN mode reproduces perihelion advance Δφ = 6πGM/[a(1−e²)c²] per orbit to < 2% (test-mass limit), with substep-convergence study confirming 2nd-order behavior | `#[cfg(test)]` module comparing one full orbit's apsidal shift to the analytic value |
| 4 | Live editors change masses/SMA/eccentricity/phase angle and Apply reinitialises the simulation from the new ICs | Manual + scripted DOM interaction |
| 5 | Follow-camera locks onto the selected body and tracks smoothly without jitter | Headless camera-offset variance measurement |
| 6 | Energy drift \|ΔE/E\| stays bounded (oscillatory, non-drifting) in Newtonian long-run, demonstrating symplectic behaviour | Plot of \|ΔE/E\| vs t exported from the sim |
| 7 | Builds offline after the Rust toolchain is installed (no crates.io fetch at build time) | `cargo build --release --target wasm32-unknown-unknown` with network disabled |

---

## 3. Tech Stack & Toolchain Decisions

### 3.1 Recommended approach (chosen): hand-built host + std-only Rust

| Layer | Choice | Rationale |
|-------|--------|-----------|
| Compute | Rust `cdylib`, crate-type `cdylib`, target `wasm32-unknown-unknown`, **std only, no external crates** | crates.io is flaky from the sandbox (HTTP 403 on its API endpoint); a zero-dependency build removes the registry as a delivery risk and keeps the bundle tiny |
| Boundary | C-ABI exports (`extern "C"`) operating on a shared `WebAssembly.Memory` buffer | Fast hot path; bulk position/trail data moves across via typed views of one ArrayBuffer instead of thousands of `postMessage` calls |
| Render | Hand-written **WebGL2** in host JS (`requestAnimationFrame` loop) | Satisfies the literal "WebGL" requirement, makes the graphics pipeline itself documentable, and avoids hiding the GL behind an abstraction layer |
| Build | `rustup` + `cargo wasm-build`; bundle with **esbuild** (`.wasm` base64-inlined into one JS) into a static `dist/` folder | Produces a server-less-friendly artifact; esbuild is available from npm (registry reachable) and bundles deterministically |

Rejected alternatives (see design review 2026-11-22):
- **`wgpu` inside Rust** — heavy dependency tree needing a working crates.io; larger bundle; hides the GL pipeline we intend to document. Offered only as a future enhancement if a single-language graphics stack is later requested.
- **Bevy / miniquad game engine** — overkill; pulls a large tree and fights the "document every calculation" goal.

### 3.2 Environment constraints (recorded)

- Sandbox has **Node v26** and **npm**; **no Rust toolchain yet** — added via `rustup` during implementation.
- **`gh` CLI is not installed** and **no GitHub credentials are cached anywhere in the sandbox**, so the remote repository and Pages deployment cannot be executed from this box without a token supplied by the user. Delivery therefore includes a fully working local artifact plus `deploy-github-pages.sh` and a README deploy section; executing the remote step waits on user-provided credentials (never guessed).
- Network: `github.com` (200) and `registry.npmjs.org` (200) reachable; `crates.io` (403) unreliable → reinforces §3.1.

---

## 4. Project Layout

```
exotic-orbits-sim/
├── Cargo.toml                 # pkg name, edition, cdylib, opt-level=3, debug-assertions off for wasm
├── src/
│   ├── lib.rs                 # extern "C" entry points + module roots
│   ├── math.rs                # vec3/mat4/quaternion, cross/dot, lookAt, perspective
│   ├── units.rs               # per-preset nondimensionalisation + SI conversion tables
│   ├── physics.rs             # N-body state, Newton + 1PN accelerations, VelocityVerlet integrator
│   ├── presets.rs             # builders returning exact IC vectors for each configuration
│   ├── trail.rs               # ring-buffer of per-body positions -> vertex staging
│   ├── render_gl.rs           # WebGL2 program compile/link, VAO/VBO for instanced spheres, line buffers, uniforms
│   └── app.rs                 # rAF driver, input glue (via js_sys/web_sys stubs kept minimal), UI-message dispatch
├── assets/
│   ├── shaders/               # .vert/.frag source (glsl)
│   │   ├── sphere.vert, sphere.frag
│   │   ├── line.vert, line.frag
│   │   ├── sprite.vert, sprite.frag        # starfield + glow halos
│   │   └── bloom.compose.frag
│   └── ui.css
├── index.html
├── main.js                    # host JS: WebGL context, shaders, geometry, rAF, DOM wiring
├── PHYSICS.md                 # full derivations (deliverable)
├── README.md                  # build/run/deploy
├── docs/superpowers/specs/    # this design doc + later impl plan
└── dist/                      # generated build output (gitignored)
```

Design principle: **one responsibility per module, plain-data in/out.** The Rust side owns all
physics and exposes `accel()`, `step(dt)`, `reinit(preset)`, `set_param(...)`, `state_snapshot()`;
the JS side owns all GL state and DOM. Neither mutates the other's private fields.

---

## 5. Unit System & Nondimensionalisation

Each preset defines its own characteristic scales so that numbers stay O(1) (this is what keeps the
fixed-timestep Verlet stable and the GR expansion parameter small and meaningful).

- **Gravitational constant:** G = 1 (internal units).
- **Mass scale:** total mass M_tot = Σ mᵢ = 1 for the equal-mass configs; for binary/flyby presets the
  primary mass m₁ is set to 1 and the secondary expressed as a mass ratio q = m₂/m₁.
- **Length scale L:** chosen so the characteristic separation is ~1 (specific choice recorded per preset
  in `units.rs`, e.g. the figure-eight equilibrium separation d₀).
- **Velocity scale:** circular-orbit scale v₀ = √(G M/L) so orbital periods are O(10–100 τ).
- **Time scale:** τ = L/v₀.
- **Softening length:** ε = 0.03 · (minimum initial pairwise separation), per preset, in internal units.

Every preset stores an **SI appendix** (kg, m, s, yr) computed from the chosen L, M, v₀ scales so the
reader can map the dimensionless showcase back to physical reality. `units.rs` holds both directions
(`to_internal`, `to_si`) with documented reference values.

The speed of light `c` is **not** set to 1: it is carried as a real number (internal units) so the
dimensionless GR expansion parameter GM/(rc²) is explicit and tunable via the GR strength knob
(§6.5).

---

## 6. Physics Model

### 6.1 Newtonian N-body (derivation)

Starting from Newton's second law and the superposition of inverse-square attractions between point
masses:

$$\mathbf{F}_i = \sum_{j \ne i} -\,\frac{G\, m_i\, m_j}{|\mathbf{r}_{ij}|^3}\,\mathbf{r}_{ij},
\qquad \mathbf{r}_{ij} = \mathbf{r}_i - \mathbf{r}_j$$

Dividing by mᵢ gives the acceleration of body i:

$$\mathbf{a}_i = \sum_{j \ne i} -\,\frac{G\, m_j}{r_{ij}^2}\,\hat{\mathbf{r}}_{ij},
\qquad \hat{\mathbf{r}}_{ij} = \frac{\mathbf{r}_{ij}}{r_{ij}}$$

The code computes exactly this (with Plummer softening, §6.3). Momentum conservation follows from
Newton's third law (equal-and-opposite pairwise forces); angular-momentum conservation follows from
central (collinear) pairwise forces. These are the quantities the diagnostic plot (§6.6) monitors to
confirm the integrator behaves as theory predicts.

### 6.2 Velocity-Verlet (leapfrog) integration

A **symplectic** scheme is chosen deliberately: a fixed-form timestep preserves a shadow Hamiltonian,
so the total energy error remains **bounded and oscillatory** rather than drifting monotonically —
this is what criterion 6 demonstrates.

Half-kick → drift → half-kick, for body i at timestep δτ:

$$\begin{aligned}
\mathbf{v}_i\!\left(t+\tfrac{\delta\tau}{2}\right) &= \mathbf{v}_i(t) + \tfrac{\delta\tau}{2}\,\mathbf{a}_i\big(\mathbf{r}(t)\big) \\
\mathbf{r}_i(t+\delta\tau) &= \mathbf{r}_i(t) + \delta\tau\,\mathbf{v}_i\!\left(t+\tfrac{\delta\tau}{2}\right) \\
\mathbf{v}_i(t+\delta\tau) &= \mathbf{v}_i\!\left(t+\tfrac{\delta\tau}{2}\right) + \tfrac{\delta\tau}{2}\,\mathbf{a}_i\big(\mathbf{r}(t+\delta\tau)\big)
\end{aligned}$$

The acceleration array is recomputed once per full step (at the new positions), giving second-order
accuracy with a per-step cost of one force evaluation per body.

### 6.3 Plummer softening

To remove the r → 0 singularity (which would otherwise demand vanishing δτ and cause catastrophic
deflection at close encounter), the separation is softened:

$$r_{ij} \;\longrightarrow\; \sqrt{r_{ij}^2 + \varepsilon^2}$$

inside the denominator only (force direction stays along the true separation vector). ε is set per
preset (§5) so it never perturbs the showcase orbit meaningfully while still regularising genuine
near-centred collisions. Its effect on the energy budget is reported in the diagnostic plot.

### 6.4 Timestep policy

- Base physical timestep δτ is defined as a fraction of the shortest characteristic orbital period of
  the active preset (default ≈ 1/256 of that period → comfortably > 200 steps per shortest orbit).
- Each rendered frame advances the simulation by an **integer** number n of substeps:

  $$n = \mathrm{clamp}\!\Big(\mathrm{round}\big(\texttt{timeScale} \cdot \Delta t_{\text{frame}} / \delta\tau\big),\; 1,\; N_{\max}\Big)$$

  where Δt_frame is the measured frame interval and N_max (default 64) caps the catch-up load when the
  tab was idle. This keeps the mapping monotonic and prevents orbit-loss after focus loss.
- When paused or when timeScale ≤ 0, n = 0.

### 6.5 First post-Newtonian (1PN) GR correction

The Newtonian potential is supplemented by the leading relativistic correction, the **Einstein–
Infeld–Hoffmann (EIH) 1PN acceleration**. Implemented pairwise along the standard non-spinning EIH
form; the coefficient set is transcribed from the two-body 1PN result cited in the literature
(Lorentz–Droste / EIH, as reproduced in *On the two-body problem in general relativity*, and the
compact notation of arXiv:gr-qc/0201050), and **validated empirically** rather than trusted to
transcription (see §6.7).

In the **test-particle limit** around a dominant central mass M, the relevant dominant correction is
the extra inward radial term proportional to GM/(c²r) times the Newtonian acceleration; summed over
all bodies it yields the well-known perihelion advance per orbit:

$$\boxed{\;\Delta\varphi = \frac{6\pi\, G M}{a\,(1-e^{2})\, c^{2}}\;}$$

This quantity is **gauge-invariant at 1PN**, so it serves as the observer-independent correctness
anchor: whichever valid EIH form is used must reproduce it. The `GRStrength` multiplier (UI knob,
default 1×, range ~0…50×) scales the entire 1PN term so precession becomes visibly fast — the primary
teaching hook — while the physical value (1×) is left as the default calibrated setting.

### 6.6 Conservation diagnostics

Per frame the simulator accumulates (in internal units): total energy
E = Σ ½mᵢvᵢ² − Σ_{j>i} G mᵢmⱼ/√(rᵢⱼ²+ε²), total linear momentum |Σ mᵢvᵢ|, and total angular
momentum |Σ mᵢ rᵢ × vᵢ|. These are exposed to the host as a 3×N float snapshot each frame and drawn as
a mini line plot (‖ΔE/E₀‖, ‖ΔP/P₀‖, ‖ΔL/L₀‖ vs simulation time). In clean Newtonian runs these stay flat
to plotting precision (criterion 6); with 1PN enabled they track the conserved PN Casimir.

### 6.7 Validation gate (implementation-time, mandatory)

Before release, `#[cfg(test)]`:
1. Launch a light test particle on an eccentric orbit around a fixed central mass M.
2. Integrate exactly one orbital period with the velocity-Verlet substepper.
3. Measure the numerically recovered apsidal shift Δφ_num.
4. Require |Δφ_num − 6πGM/[a(1−e²)c²]| / (analytic value) < 2%, repeated at three substep densities to
   confirm second-order convergence (ratio of errors ≈ 4 when δτ is halved).
5. If the chosen EIH coefficient form fails, fall back to the Barker–O'Connell / isotropic-EIH variant
   until the invariant observable is matched; record which form passed in `PHYSICS.md`.

---

## 7. Initial Configurations (Presets)

All coordinates/velocities are listed in internal units in `presets.rs`. Each is checked for long-term
stability (≥ 500 orbits) before release (§2, criterion 2).

| # | Name | Description | Stability note |
|---|------|-------------|----------------|
| 1 | **Figure-eight** | Equal-masses planar periodic orbit (Chenciner–Montgomery, Cris Moore 2000) | Exactly periodic; sensitive to integrator round-off — good symplecticity probe |
| 2 | **Square Klemperer rosette** | Four equal masses at square vertices, co-rotating under mutual gravity | Exact relative equilibrium in the restricted sense; marginally unstable — show ideal run *and* a ¼-phase-perturbed run side by side |
| 3 | **Lagrange equilateral triangle** | Three masses at equilateral corners, circular mutual orbit + small test-mass cluster near L₄/L₅ | Demonstrates co-orbital stability of the triangular points |
| 4 | **Eccentric hierarchical flyby** | Two unequal masses on a high-eccentricity Keplerian encounter | Visually dramatic approach/fast-scattering; showcases 1PN apsidal motion |
| 5 *(optional bonus)* | **Solar System (scaled)** | Correct relative planetary periods on elliptical orbits | Comparison reference against the exotic set; cheap to add |

Editable parameters per body: **mass**, **semi-major axis**, **eccentricity**, **phase angle**; global
toggle **freeze** per body; Apply reinitialises from the constructed ICs, Reset restores the preset.

---

## 8. Rendering Pipeline (WebGL2)

Frame order (JS owns all GL state):

1. **Clear** depth + color.
2. **Starfield**: instanced billboard quads (point sprites) with additive blending; faint gradient
   dome background via a fullscreen triangle fragment.
3. **Scene RTT at ½ resolution** (ping-pong FBOs):
   - **Geometry**: icosahedron subdivision → ~1024 triangles/body, **instanced** (`gl_InstanceID`),
     transformed by instance matrix (scale + rotation from orientation quaternion updated from angular
     velocity — spin shown aligned to the orbit normal for clarity).
   - **Shading**: procedural **fbm albedo texture** per body (analytic value noise in the fragment
     shader — no image files needed, works from `file://`), **Blinn-Phong** diffuse + specular; light
     contribution summed over the ≤ 8 luminous bodies with 1/r² attenuation (bright bodies also emit
     their own colour).
   - Depth-tested, depth-masked.
4. **Bloom**: extract luminance from the ½-res scene, **3-pass separable Gaussian** (box kernel) on the
   downscaled ping-pong FBOs, **additive composite** back at full resolution.
5. **Post**: Reinhard tone-map + γ 2.2 + subtle vignette.
6. **Trails last**: per-body age-faded line strips from dynamic `glBufferData(DYNAMIC_DRAW)` rings,
   blended low-alpha with front-face masking.

**Performance budget:** ½-res RTT + capped ≤8 lights + 3-pass bloom keeps fragment work modest; if
fps drops below threshold the host auto-reduces sphere tessellation order and/or bloom passes (adaptive,
logged, never silently degrades quality below a readable minimum).

---

## 9. Camera & Controls

- **Free orbit**: spherical azimuth/elevation/radius around a focus point (center-of-mass by default),
  exponential damping, scroll/pinch zoom, middle/right-drag or two-finger pan.
- **Follow mode**: focus locked onto the selected body; target offset smoothed with **predicted-motion
  compensation** so the camera does not lag-jitter during high-speed passages.
- **Selection**: click raycasts against each body's projected disc radius (screen-space radius from the
  view-space distance and model radius); UI row highlight syncs bidirectionally.
- **Keyboard**: space (pause), `±` (log time scale), R (reset current preset), F (toggle follow), Tab
  (cycle preset), `?` (help drawer).

---

## 10. Interactivity / UI

Glassmorphism overlay panel (host HTML/CSS, not WASM-rendered):
- Preset picker (dropdown), play/pause, logarithmic speed slider with numeric readout.
- Per-body rows: freeze ✓ checkbox; sliders for mass / SMA / eccentricity / phase-angle; **Apply** and
  **Reset** buttons; highlighted row for the selected body.
- Global readouts: simulation time (with day/year label mapped via `units.rs`), \|ΔE/E\| live plot, fps.
- Help drawer listing all keyboard shortcuts.

Live edits recompute ICs on **Apply** (full reinitialisation, preserving freezed-body flags); in-run
tweaks of phase/ecc send an immediate gentle rebind for responsiveness, committed cleanly on Apply.

---

## 11. Deliverables Documentation

- **`PHYSICS.md`** (primary): §1 unit conventions; §2 Newtonian derivation (6.1); §3 velocity-Verlet
  discretisation & symplectic rationale (6.2); §4 softening (6.3); §5 timestep/substepping (6.4);
  §6 1PN EIH statement + invariant-anchor validation method + SI mapping per preset (6.5–6.7); §7
  rendering notes (geometry generation, Blinn-Phong summation, bloom pass count, trails).
- **Inline Rust docs** on every public function/module boundary.
- **README.md**: prerequisites (rustup + one target), build commands, run instructions, ESBuild-based
  static serve, GitHub Pages deploy path.

---

## 12. Build & Deploy

```
rustup toolchain install stable && rustup component add rust-src
rustup target add wasm32-unknown-unknown
cargo build --release --target wasm32-unknown-unknown      # offline-capable: no registry fetch
npx esbuild ...  -> dist/index.html + dist/assets/app.wasm (base64-inline)
# optional local verify: npx serve dist  (or the project's tiny node static server)
```

GitHub Pages: `deploy-github-pages.sh` clones the created repo guarded against double creation, pushes
`dist/` to the `pages` branch (or sets `static` source on `main`), enables the Pages source, and prints
the URL. Requires `gh` auth present on the machine that runs it (none exists in this sandbox yet).

---

## 13. Verification Plan

| Stage | What | Where |
|-------|------|-------|
| Unit tests | 1PN perihelion precession anchor (§6.7); mat4/quaternion identities; softening limit checks | `src/`, `#[cfg(test)]`, `cargo test --target wasm32...` |
| Long-run stability | ≥ 500 orbits per preset, min-separation floor + bounded energy drift printed | headless harness built into `app` |
| Performance | ≥ 50 fps native, GPU frame-time profiled via `WEBGL_debug_renderer_info` + JS timing | headless browser capture |
| Cross-browser sanity | Chrome/HeadlessChrome; note any WebGL2 extension gaps | automated screenshot compare |
| Delivery | page loads over HTTP, console clean (no unhandled rejection/WASM load error), fps + energy-drift readouts populated | final acceptance pass |

---

## 14. Open Items & Risks

| Item | Risk | Mitigation |
|------|------|-----------|
| GitHub authentication | Cannot create repo / push from sandbox without a token | Local artifact complete + one-command deploy script; remote execution gated on user-supplied credential (never guessed) |
| crates.io connectivity | 403 observed | Avoided entirely: std-only Rust, hand-written GL host |
| 1PN coefficient transcription | OCR/textbook formula risk | Empirical invariant-anchor gate (§6.7); document which form passed |
| Bloom/perf on integrated GPUs | Fragment cost at ½ res | Adaptive tessellation/bloom (§8 performance budget) |
| Follow-camera jitter at high speed | Predicted-motion compensation required | Designed in (§9); validated by offset-variance measurement |
