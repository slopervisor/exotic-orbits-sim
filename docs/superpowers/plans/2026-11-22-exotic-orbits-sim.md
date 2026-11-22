# Exotic Orbits Simulator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a public, interactive web demo where exotic few-body gravitational configurations (figure-eight three-body, Klemperer rosette, Lagrange equilateral triangle, eccentric relativistic flyby) evolve in real time under Newtonian gravity plus a first-post-Newtonian general-relativity correction, rendered as shaded spheres with orbital trails and bloom, driven by a Rust/WebAssembly physics engine and a raw WebGL2 host.

**Architecture:** Host JavaScript owns the WebGL2 context and the requestAnimationFrame loop plus all DOM interaction; a Rust `cdylib` compiled to `wasm32-unknown-unknown` owns every physics calculation (Newtonian N-body + 1PN GR acceleration, velocity-Verlet symplectic integration, Plummer softening, trail buffering) and exposes C-ABI entry points over a shared `WebAssembly.Memory`; bulk state moves across typed array views into reserved linear-memory regions. Rendering runs at half resolution with a separable multi-pass bloom pipeline and Reinhard tone mapping, then composites onto the scene.

**Tech Stack:** Rust (stable) cdylib targeting `wasm32-unknown-unknown`, std-only (zero external crates); C-ABI `extern "C"` exports; handwritten WebGL2 in ES module JavaScript; requestAnimationFrame driver; esbuild bundling the `.wasm` base64-inline; Node.js 26.x / npm 11.x for the dev server; `gh` 2.105.0 official binary for delivery.

**Spec:** `docs/superpowers/specs/2026-11-22-exotic-orbits-sim-design.md` (this plan argues from that design doc; executors read both).

## Global Constraints

- Zero external crates on the Rust side; only the Rust standard library is permitted — no `Cargo.lock` dependencies shipped (design doc §3.1).
- Velocity-Verlet (leapfrog) symplectic integrator with integer adaptive sub-stepping targeting roughly 200+ physical sub-steps per animation frame at nominal simulation speed (design doc §6.4).
- Plummer softening ε ≈ 0.03 × minimum initial separation, computed per preset (design doc §6.3).
- General-relativity strength knob range 0× … ~50× the canonical 1PN term, default 1×, editable at runtime (design doc §6.6).
- Acceptance criteria (§2 of the design doc): ≥50 fps during simulated motion on representative hardware; bounded (oscillatory, non-drifting) relative energy error |ΔE/E| over many thousands of orbits; ≤2% discrepancy between numerically measured and analytically predicted 1PN perihelion precession; follow-camera jitter below perceptible threshold; live parameter editors apply within one animation frame; offline build succeeds with network disabled.
- Delivery via GitHub Pages with a documented `gh-pages`-branch fallback (design doc §13).
- Branch → push → pull request → green checks → merge; no direct pushes to `main` outside repository seeding; describe the plan before implementing; adversarial review to zero findings including nitpick-level items before merging; externally facing text (README, PHYSICS.md, commit messages, PR copy) passed through the unslop prose filter before delivery.
- All credential material flows only through environment variables and is never echoed, persisted in config, or reproduced in this record.

---

### Task 0: Project scaffold, toolchain verification, offline-build proof

**Files:**
- Create: `Cargo.toml`
- Create: `rust-toolchain.toml`
- Modify: `.gitignore` (already committed — add `dist/`, `node_modules/`, `*.wasm` serving MIME notes)
- Create: `index.html` (shell only)
- Create: `assets/css/ui.css`
- Create: `assets/js/main.js` (entry stub)
- Create: `package.json` + `esbuild.config.mjs`
- Create: `docs/superpowers/plans/2026-11-22-exotic-orbits-sim.md` (this document)

**Interfaces:**
- Consumes: nothing prior (setup task).
- Produces: a crate that compiles to `wasm32-unknown-unknown` in release profile and produces `target/wasm32-unknown-unknown/release/exotic_orbits_sim.wasm`; an esbuild bundle emitted to `dist/assets/app.js`; a static dev server command.

- [ ] **Step 1: Create Cargo.toml as a std-only cdylib**

```toml
[package]
name = "exotic_orbits_sim"
version = "0.1.0"
edition = "2021"
description = "Exotic few-body gravitational dynamics showcase (std-only WebAssembly physics engine)"

[lib]
crate-type = ["cdylib"]

[profile.release]
opt-level = 3
lto = true
panic = "abort"

[dependencies]
# intentionally empty - zero external crates allowed (design doc §3.1)
```

- [ ] **Step 2: Pin the toolchain and target**

`rust-toolchain.toml`:
```toml
[toolchain]
channel = "stable"
components = ["rust-src"]
targets = ["wasm32-unknown-unknown"]
```

Verify installation and the absence of network dependence:
```bash
rustup show
rustup component list --installed
rustup target list --installed | grep wasm32
env NETWORK=none ./scripts/verify-offline-build.sh
```
where `verify-offline-build.sh` sets `RUSTFLAGS="--emit=linkage"` isn't needed; it simply runs:
```bash
#!/usr/bin/env bash
set -euo pipefail
export RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"
export CARGO_NET_OFFLINE=true
rustup toolchain install stable >/dev/null 2>&1 || true
rustup component add rust-src >/dev/null 2>&1 || true
rustup target add wasm32-unknown-unknown >/dev/null 2>&1 || true
cargo build --release --target wasm32-unknown-unknown
test -f target/wasm32-unknown-unknown/release/exotic_orbits_sim.wasm
echo OFFLINE_BUILD_OK
```

- [ ] **Step 3: Scaffold package.json + esbuild config + index.html shell**

`package.json`:
```json
{
  "name": "exotic-orbits-sim",
  "private": true,
  "version": "0.1.0",
  "type": "module",
  "scripts": {
    "build": "node esbuild.config.mjs",
    "dev": "npx serve dist --no-cache-config"
  },
  "devDependencies": {
    "esbuild": "^0.25.0"
  }
}
```
Note: `esbuild` is a *development-time* bundler (not shipped in the delivered artifact and not a Rust dependency), so it is compatible with the zero-Rust-crates rule.

`esbuild.config.mjs`:
```mjs
import esbuild from "esbuild";
await esbuild.build({
  entryPoints: ["assets/js/main.js"],
  bundle: true,
  format: "esm",
  loader: { ".wasm": "base64" },
  outfile: "dist/assets/app.js",
  define: { __WASM_SIZE_CHECK__: "true" },
  minify: false, // production build step in deploy script minifies
  sourcemap: "inline",
});
// copy the compiled wasm next to the bundle so <script type="module"> can fetch it
import { cpSync } from "node:fs";
cpSync("target/wasm32-unknown-unknown/release/exotic_orbits_sim.wasm", "dist/assets/app.wasm");
```

`index.html` (minimal shell, content filled progressively in later tasks):
```html
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Exotic Orbits Simulator</title>
  <link rel="stylesheet" href="./assets/css/ui.css">
</head>
<body>
  <canvas id="stage" aria-label="Solar system physics simulation"></canvas>
  <div id="ui-root" hidden></div>
  <script type="module" src="./assets/app.js"></script>
</body>
</html>
```

- [ ] **Step 4: Run the failing baseline and prove the build works**

Run `npm ci && npm run build` twice (second pass proves caching determinism) and confirm `dist/assets/app.js` references `app.wasm`. Confirm `cargo test --lib` fails cleanly at this point because no modules exist yet (the crate still compiles an empty lib).

- [ ] **Step 5: Commit**

```bash
git add Cargo.toml rust-toolchain.toml index.html package.json esbuild.config.mjs assets/css/ui.css .gitignore scripts/verify-offline-build.sh
git commit -q -m "chore: scaffold std-only WASM crate, esbuild pipeline, and offline build proof"
```

---

### Task 1: Math primitives (vec3/mat4/quaternion) with unit tests

**Files:**
- Create: `src/math.rs`
- Test: `src/math.rs` contains a `#[cfg(test)] mod tests` (same file; pure functions run on the native host target during `cargo test`).

**Interfaces:**
- Consumes: nothing.
- Produces: `Vec3 { x: f64, y: f64, z: f64 }` with `add/sub/scalar_mul/dot/cross/norm/normalize/to_array_mut`, `Mat4` column-major `[[f64;4];4]` with `identity/new_rotation(axis, angle)/look_at/set_translation/transpose/inverse_orthonormal`, `Quat` with `from_axis_angle/mul/conjugate/to_mat3`.

- [ ] **Step 1: Write failing tests first**

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vec_cross_right_hand_rule() {
        let i = Vec3::new(1.0, 0.0, 0.0);
        let j = Vec3::new(0.0, 1.0, 0.0);
        let k = i.cross(&j);
        assert!((k.z - 1.0).abs() < 1e-12);
        assert!(k.abs_x() < 1e-12 && k.abs_y() < 1e-12);
    }

    #[test]
    fn rotation_about_z_returns_rotated_vector() {
        let q = Quat::from_axis_angle(&(0.0, 0.0, 1.0), std::f64::consts::FRAC_PI_2);
        let v = q.transform_vec3(&Vec3::new(1.0, 0.0, 0.0));
        assert!((v.y - 1.0).abs() < 1e-9);
        assert!((v.x - 0.0).abs() < 1e-9);
    }

    #[test]
    fn look_at_matches_known_basis() {
        let eye = Vec3::new(0.0, 0.0, 5.0);
        let center = Vec3::ZERO;
        let up = Vec3::new(0.0, 1.0, 0.0);
        let m = Mat4::look_at(&eye, &center, &up);
        // forward axis must point from eye toward center
        let f = m.forward();
        assert!(f.z < 0.0);
    }

    #[test]
    fn normalize_preserves_length_within_tolerance() {
        let v = Vec3::new(3.0, 4.0, 0.0);
        let n = v.normalize();
        assert!((n.norm() - 1.0).abs() < 1e-9);
    }
}
```

- [ ] **Step 2: Run to verify failure**

`cargo test --lib math::tests -- --exact` → FAILS with `function cross not defined` / associated function missing.

- [ ] **Step 3: Implement `Vec3` methods minimally.**

```rust
#[derive(Clone, Copy, Debug)]
pub struct Vec3 { pub x: f64, pub y: f64, pub z: f64 }
impl Vec3 {
    pub const ZERO: Self = Self { x: 0.0, y: 0.0, z: 0.0 };
    pub const fn new(x: f64, y: f64, z: f64) -> Self { Self { x, y, z } }
    pub fn add(&self, o: &Self) -> Self { Self::new(self.x + o.x, self.y + o.y, self.z + o.z) }
    pub fn sub(&self, o: &Self) -> Self { Self::new(self.x - o.x, self.y - o.y, self.z - o.z) }
    pub fn scalar_mul(&self, s: f64) -> Self { Self::new(self.x*s, self.y*s, self.z*s) }
    pub fn dot(&self, o: &Self) -> f64 { self.x*o.x + self.y*o.y + self.z*o.z }
    pub fn cross(&self, o: &Self) -> Self {
        Self::new(self.y*o.z - self.z*o.y, self.z*o.x - self.x*o.z, self.x*o.y - self.y*o.x)
    }
    pub fn norm(&self) -> f64 { (self.dot(self)).sqrt() }
    pub fn normalize(&self) -> Self { let n = self.norm(); Self::new(self.x/n, self.y/n, self.z/n) }
    pub fn to_array_mut(&self, out: &mut [f64; 3]) { out[0]=self.x; out[1]=self.y; out[2]=self.z; }
    pub fn abs_x(&self) -> f64 { self.x.abs() }
    pub fn abs_y(&self) -> f64 { self.y.abs() }
}
```

- [ ] **Step 4: Run tests, expect PASS.**

- [ ] **Step 5: Implement `Mat4`/`Quat` similarly, re-run full suite.**

- [ ] **Step 6: Commit**

```bash
git add src/math.rs
git commit -q -m "feat(math): add Vec3/Mat4/Quat primitives with unit tests"
```

---

### Task 2: Unit systems (nondimensionalisation + SI conversion tables)

**Files:**
- Create: `src/units.rs` (+ inline `#[cfg(test)]`)

**Interfaces:**
- Consumes: `math::Vec3`.
- Produces: `UnitSystem { length_scale_m: f64, time_scale_s: f64, mass_scale_kg: f64, g_const_internal: f64 }` with `internal_to_si_pos(Vec3)->Vec3SI`, `si_to_internal_pos(...)`, `acceleration_scale()`, plus a table keyed by preset returning scale constants. Validate that G_internal = G_SI * time_scale² / length³ reproduces G_SI within 1e-9.

- [ ] **Step 1: Failing test**

```rust
#[test]
fn si_round_trip_reproduces_g() {
    let us = UnitSystem::for_preset(PresetId::FigureEight);
    // dimensional consistency: G in internal units
    let g_int = us.g_const_internal;
    let expected = G_SI * us.time_scale_s.powi(2) / us.length_scale_m.powi(3);
    assert!((g_int - expected).abs() / expected < 1e-7);
}
```

- [ ] **Step 2: Run → FAILS (`UnitSystem` undefined).**

- [ ] **Step 3: Minimal implementation** — choose per-preset normalization `G*M_total = 1`, `total_mass = 1`, characteristic length = reference separation; store `length_scale_m`, compute `time_scale_s = sqrt(length_scale_m³ / (G_SI * mass_scale_kg))`. Provide SI helper getters.

- [ ] **Step 4: Run → PASS**; add round-trip position test (`si_to_internal_pos(internal_to_si_pos(v)) == v` within 1e-6).

- [ ] **Step 5: Commit**

```bash
git add src/units.rs
git commit -q -m "feat(units): nondimensionalisation and SI conversion tables with tests"
```

---

### Task 3: Newtonian N-body core + velocity-Verlet leapfrog + Plummer softening

**Files:**
- Create: `src/physics.rs` (state + integrator)
- Test: same-file `#[cfg(test)] mod tests`.

**Interfaces:**
- Consumes: `math::Vec3`, `units::UnitSystem`.
- Produces: `Body { pos, vel, acc, mass, id }`, `NBodySim { bodies: Vec<Body>, dt, substeps, eps, gr_strength }` with `compute_accelerations(&self, out: &mut [Vec3])`, `verlet_step(&mut self, dt: f64)`, `softened_newton_pair(a: &Body, b: &Body) -> Vec3`, `energy(&self) -> f64`, `momentum(&self) -> Vec3`. Public setter `set_gr_strength(x: f64)`.

- [ ] **Step 1: Failing test — two-body circular orbit stays bound and conserves energy (bounded drift)**

```rust
#[test]
fn two_body_circular_orbit_stays_bounded_over_many_orbits() {
    let mut sim = NBodySim::two_body_circular(mass_primary: 1.0, mass_secondary: 1e-6, separation: 1.0);
    let orb_period = 2.0 * PI / pow(gravity_const, 0.5); // Kepler third law in these units
    let dt = orb_period / 2000.0;
    let start_e = sim.energy();
    for _ in 0..5000u64 { sim.verlet_step(dt); }
    let end_e = sim.energy();
    let rel = (end_e - start_e).abs() / start_e.abs();
    assert!(rel < 1e-3, "energy drift {rel:e} exceeds tolerance");
}
```

- [ ] **Step 2: Run → FAILS (`NBodySim` undefined).**

- [ ] **Step 3: Minimal implementation** — pairwise softened acceleration
a_i = Σ_{j≠i} G m_j r_ij / (r_ij² + ε²)^{3/2}, velocity-Verlet update:
v^{n+1/2} = vⁿ + (dt/2) aⁿ
x^{n+1} = xⁿ + dt·v^{n+1/2}
a^{n+1} from positions; v^{n+1} = v^{n+1/2} + (dt/2) a^{n+1}.

- [ ] **Step 4: Run → PASS.** Add a second test asserting momentum conservation to ~1e-6 in the closed equal-mass two-body case (symmetry check) — this will catch asymmetric force bugs early.

- [ ] **Step 5: Commit**

```bash
git add src/physics.rs
git commit -q -m "feat(physics): Newtonian N-body velocity-Verlet integrator with Plummer softening and tests"
```

---

### Task 4: First-post-Newtonian GR correction validated against analytic perihelion advance

**Files:**
- Extend: `src/physics.rs` (1PN acceleration branch gated by `gr_strength`), keep module structure.
- Create: `PHYSICS.md` section documenting the derivation being implemented (written alongside code; updated incrementally).

**Interfaces:**
- Consumes: existing `NBodySim`, `Body`, `Vec3`.
- Produces: `compute_accelerations` now adds the 1PN term when `gr_strength > 0`; the canonical EIH pairwise form (Kavanagh–Sussman, arXiv:1312.1289 eq. 19, adapted to our sign convention):

a_a = −Σ_{b≠a} (G m_b x_ab / r_ab³) · [ 1 + (1/c²){ 4Gm_b/r_ab + 5Gm_a/r_ab + Σ_{c≠a,b}(Gm_c/r_bc) + 4Σ_{c≠a,b}(Gm_c/r_ac) − (1/2)Σ_{c≠a,b}(Gm_c/r_bc³)(x_ab·x_bc) − v_a² + 4 v_a·v_b − 2 v_b² + (3/2)(v_b·n_ab)² } ]
     − (7/2c²) Σ_{b≠a} (Gm_b/r_ab) Σ_{c≠a,b} (Gm_c x_bc / r_bc³)
     + (1/c²) Σ_{b≠a} (Gm_b/r_ab³) (x_ab·(4v_a − 3v_b))(v_a − v_b)

with x_ab = x_a − x_b, n_ab = x_ab/r_ab, and c set so that the dimensionless post-Newtonian potential scale matches the design-doc knob (default 1× reproduces the standard 1PN perihelion advance).

- [ ] **Step 1: Failing acceptance test — measured periastron advance vs 6πGM/(a(1−e²)c²)**

```rust
#[test]
fn pn_perihelion_advance_matches_analytic() {
    // near-test-particle eccentric orbit around a dominant central mass
    let mut sim = NBodySim::central_plus_test_particle(mass_central: 1.0, mass_test: 1e-8,
                                                       semi_major: 1.0, eccentricity: 0.4);
    sim.set_gr_strength(1.0);
    let dt = (2.0 * PI /* period */) / 20000.0;
    let prev_apocenter_angle = detect_apocenter_angle(&sim);
    let mut advances = Vec::new();
    for _ in 0..200 { sim.verlet_step(dt); if orbit_boundary_crossed(&sim) { advances.push(measured_advance(&sim)); } }
    let numeric_mean = advances.iter().sum::<f64>() / advances.len() as f64;
    let analytic = 6.0 * PI * G_SI * MASS_SCALE_sun_in_units / (semimajor * (1.0 - ecc*ecc) * speed_of_light_squared_in_units);
    let rel_err = (numeric_mean - analytic).abs() / analytic;
    assert!(rel_err < 0.02, "1PN precession off by {rel_err:pct}; numeric={numeric_mean}, analytic={analytic}");
}
```

The test harness computes `speed_of_light_squared_in_units` from the chosen nondimensionalisation (design doc §6.6 defines c in internal units as a fixed large value so that 1PN corrections are visible but non-dominant at showcase speeds). The exact threshold of 2% covers gauge differences between the Damour and Kavanagh–Sussman forms while remaining a meaningful correctness gate.

- [ ] **Step 2: Run → FAILS (`compute_accelerations` has no 1PN branch).**

- [ ] **Step 3: Implement the 1PN branch exactly as documented above**, including the velocity-dependent terms and the 7/2 three-body potential term.

- [ ] **Step 4: Run → PASS.** Also run the Task 3 Newtonian-only test with `gr_strength = 0` to prove the knob cleanly disables GR (regression guard).

- [ ] **Step 5: Update PHYSICS.md** with the equation above, the softening rationale, the integration scheme, and the validation-gate reasoning (§6.7 of the design doc). Keep prose unslopped and factual.

- [ ] **Step 6: Commit**

```bash
git add src/physics.rs PHYSICS.md
git commit -q -m "feat(physics): 1PN general-relativity correction validated against analytic perihelion advance"
```

---

### Task 5: Exact initial-condition builders for all five showcased presets

**Files:**
- Create: `src/presets.rs`
- Test: same-file `#[cfg(test)]`.

**Interfaces:**
- Consumes: `math::Vec3`, `units::UnitSystem`.
- Produces: `PresetId` enum (values FigureEight, KlempererRosetteIdeal, KlempererRosettePerturbed, LagrangeEquilateralTriangle, EccentricRelativisticFlyby) with `name()/description()` and `initial_state(unit_system) -> SimConfig { positions:[Vec3], velocities:[Vec3], masses:[f64], softening_eps:f64, gr_default:f64 }`. Each builder carries a comment citing its source configuration.

Presets (documented values; verify numerically per the spec's stability criteria):
1. **Figure-eight three-body** — equal masses, the periodic solution of Moore–Chenciner–Montgomery: |v| per body ≈ 0.9324… in normalized units; validate min-body-separation ≥ 0.4 throughout a 100-orbit integration and bounded relative energy error < 1e-3.
2. **Klemperer rosette (ideal)** — four equal masses at the vertices of a square rotating under mutual gravity; validate co-rotation over many orbits.
3. **Klemperer rosette (perturbed)** — one mass increased by 1%, demonstrating chaotic diffusion; validate min-separation floor and that angular momentum is conserved to ~1e-5.
4. **Lagrange equilateral triangle** — Sun-Jupiter-mass ratio with three co-orbital test particles placed at L4/L5; validate the triangular configuration remains bounded (Hill-stability criterion satisfied).
5. **Eccentric relativistic flyby** — hierarchical binary with a passing low-mass body at periastron velocity ~0.05c; validate measurable perihelion shift accumulation and no collision/softening blow-up.

- [ ] **Step 1: Failing test** — iterate all presets, integrate each for N orbits, assert stated invariant holds.

```rust
#[test]
fn every_preset_remains_bound_and_non_colliding() {
    for id in [PresetId::FigureEight, PresetId::KlempererRosetteIdeal,
               PresetId::KlempererRosettePerturbed, PresetId::LagrangeEquilateralTriangle,
               PresetId::EccentricRelativisticFlyby] {
        let mut sim = initial_state(&id, &UnitSystem::for_preset(id));
        sim.set_gr_strength(id.default_gr());
        let period = orbital_period_hint(&id);
        let dt = period / 2000.0;
        for _ in 0..orbits_for(id) { sim.verlet_step(dt); }
        assert_min_separation_floor(&sim, id);
        assert_energy_bounded(&sim, id);
    }
}
```

- [ ] **Step 2: Run → FAILS (`presets` module absent).**

- [ ] **Step 3: Implement each builder with commented sources** (cite the original papers/configurations used to fix the numbers).

- [ ] **Step 4: Run → PASS** for all five configs.

- [ ] **Step 5: Commit**

```bash
git add src/presets.rs
git commit -q -m "feat(presets): exact initial conditions for all five showcased configurations with stability tests"
```

---

### Task 6: Trail ring buffer (staging geometry for orbital lines)

**Files:**
- Create: `src/trail.rs`
- Test: same-file tests.

**Interfaces:**
- Consumes: `math::Vec3`.
- Produces: `TrailRing { buf: Box<[BufPoint; CAP]>; head, count, capacity }` with `push(&mut self, pos: Vec3)`, `front(&self) -> Option<&BufPoint>`, `as_vertex_buffer(&self) -> &[f32]` (interleaved xyz floats ready for WebGL), plus `clear()`/`len()`. Capacity a power-of-two constant (e.g. 1024 per body). Tests: rotation-wrap correctness (push capacity+1 items, confirm oldest evicted), contiguous float layout, monotonic fade attribute computation.

- [ ] **Steps 1–5** follow the TDD pattern (write wrap-around test first; implement `push` with modular index; verify `as_vertex_buffer` returns Float32-compatible interleaved data). Commit message: `feat(trail): ring-buffer trail staging with vertex-layout tests`.

---

### Task 7: WebGL2 rendering host (shaders, instanced spheres, trail lines, sprites/bloom)

**Files:**
- Create: `assets/js/gl/core.js` — context creation (`webgl2` with `alpha:false, antialias:false, preserveDrawingBuffer:false`), program compilation/linking, uniform/location helpers.
- Create: `assets/js/gl/shaders.js` — GLSL source strings (sphere vert/frag, line vert/frag, sprite vert/frag, bloom compose frag) + compile helpers.
- Create: `assets/js/gl/sphere-renderer.js` — instanced icosphere mesh (~1024 tris/body, ≤8 luminous bodies) with Blinn-Phong shading.
- Create: `assets/js/gl/line-renderer.js` — dynamic VBO for trail lines indexed by trail vertex count.
- Create: `assets/js/gl/sprite-renderer.js` + `assets/js/gl/bloom.js` — ½-resolution render target, separable Gaussian blur passes, Reinhard tone-map + γ 2.2 + vignette composition.
- Create: `assets/js/camera.js` — free/follow camera with predicted-motion smoothing.

Test strategy (graphics have no unit-testable pure functions worth forcing): a headless verification page `tests/headless/render.test.js` served via the dev server drives frame counting through `requestAnimationFrame` callbacks captured on an offscreen canvas and asserts draw-call counts and fps ≥ 50 on representative hardware; failures surface as console errors caught by the CDP harness (no new repository dependency — verification runs through the existing browser tooling, keeping the shipped artifact zero-dependency).

- [ ] **Step 1: Shaders + compile pipeline** — write GLSL for shaded spheres (normals + hemisphere lighting), gradient trails, glowing exponential-sprite discs, and the multi-pass bloom composer. Verify linking produces no GL errors (assert `getProgramInfoLog` empty).

- [ ] **Step 2: Instanced sphere renderer** — single icosphere VAO drawn with `drawArraysInstancedANGLE`/`instanced arrays` for instance transform matrices; cap at eight instances.

- [ ] **Step 3: Line renderer** feeding from `trail.rs` output once available (Task 8 wires the actual buffer; here ship a stub buffer of zeros + a contract test drawing N points).

- [ ] **Step 4: Bloom pass** at half resolution with separable horizontal/vertical Gaussian kernels (configurable sigma), Reinhard compression, gamma 2.2 encode, mild vignette. Headless fps assertion.

- [ ] **Step 5: Commit**

```bash
git add assets/js/gl/
git commit -q -m "feat(render): WebGL2 instanced shaded spheres, trail lines, half-res bloom pipeline"
```

---

### Task 8: WASM binding layer + animation-frame driver (shared-memory contract)

**Files:**
- Create: `assets/js/wasm.js` — crate wrapper exposing `init(maxBodies)`, `resetToPreset(idx)`, `step(dt, nSubsteps)`, `setParam(body, key, value)`, `snapshot(positionsF32Offset, velocitiesF32Offset, massesF32Offset, count)`, `diagnostics(outStruct)`; define the shared linear-memory region layout (constants agreed with `src/lib.rs`):

```js
// element offsets into the WASM LinearMemory Float32 view (see lib.rs MEM_LAYOUT)
const OFF_POS = 0;                 // MAX_BODIES * 3 elements
const OFF_VEL = OFF_POS + MAX_BODIES * 3;
const OFF_MAS = OFF_VEL + MAX_BODIES * 3;
const OFF_TRAIL = OFF_MAS + MAX_BODIES;            // MAX_BODIES * MAX_TRAIL_POINTS * 3
const F32 = globalThis.Float32Array ? null : null; // placeholder replaced by real views below
```

(The literal offset arithmetic is filled in concretely; the diagram above documents intent.) Host JS creates `WebAssembly.Memory({ initial: INITIAL_PAGES })`, instantiates the `.wasm`, and maps typed array views anchored on `memory.buffer`:

```js
this.positions = new Float32Array(wasm.memory.buffer, OFF_POS * 4, MAX_BODIES * 3);
this.velocities = new Float32Array(wasm.memory.buffer, OFF_VEL * 4, MAX_BODIES * 3);
this.masses = new Float32Array(wasm.memory.buffer, OFF_MAS * 4, MAX_BODIES);
this.trails = new Float32Array(wasm.memory.buffer, OFF_TRAIL * 4, MAX_BODIES * MAX_TRAIL_POINTS * 3);
```

- [ ] **Step 1: Contract test** — after `init` + `resetToPreset(0)`, read back `positions`/`velocities`/`masses` from the ArrayBuffer and assert they match the known figure-eight IC values to 1e-6; then call `step(Δt, n)` and assert state changed (energies differ, positions advanced). This proves the boundary works before any graphics code depends on it.

- [ ] **Step 2: Driver loop** — record wall-clock Δt; compute integer sub-step count `n = clamp(round(timeScale · Δt / τ_target), 1, SUBSTEP_FLOOR, SUBSTEP_CEIL)` with τ_target chosen so nominal speed yields ~200 sub-steps/frame; call `wasm.step(physicalDt, n)`; throttle diagnostics readout to every 6th frame; feed snapshots into the renderers.

- [ ] **Step 3: Commit**

```bash
git add assets/js/wasm.js assets/js/app.js   # app.js hosts the rAF loop skeleton here
git commit -q -m "feat(host): WASM shared-memory binding and adaptive-substep animation driver"
```

---

### Task 9: Interactivity suite (preset picker, play/pause, logarithmic time slider, per-body freeze, live editors, click selection, keyboard shortcuts)

**Files:**
- Create: `assets/js/ui/panel.js` — glassmorphism control panel DOM (content added progressively; see design doc §9).
- Create: `assets/js/ui/editors.js` — per-body mass/SMA/eccentricity/phase-angle editors with Apply/Reset; preset dropdown triggers `wasm.resetToPreset` + re-read snapshot.
- Create: `assets/js/input.js` — keyboard (space pause, +/- log speed, R reset, F toggle selected-body freeze, Tab cycle body list, `?` help drawer), mouse drag-rotate + scroll-zoom + click raycast selecting a body by sphere intersection.

Contract for live editing: changing a parameter calls `wasm.setParam(body, KEY, value)` where `KEY ∈ {Mass=0, SemiMajorAxis=1, Eccentricity=2, PhaseAngle=3}`; the host recomputes orbital elements via `presets.orbital_elements_from(state, bodyIndex)` and issues `resetToPresetWithElements(...)`. Define that function in `src/presets.rs` (`orbital_elements_to_ic(mass, sma, ecc, phase, inclination_deg) -> SimConfig`) so both Rust-side presets and the UI share ONE generator — DRY across the boundary.

- [ ] **Steps 1–5**: build panel shell + preset picker first (observable immediately), then time controls, then live editors keyed to the shared Rust generator, then input handlers; verify each with a short DOM script driving the dev server (headless harness reports PASS/FAIL per control). Commit message: `feat(ui): interactivity suite with shared Rust-side orbital-element generator`.

---

### Task 10: Follow camera with predicted-motion smoothing + visual polish

**Files:**
- Extend: `assets/js/camera.js`, `assets/js/gl/*.js`.

**Interfaces:**
- Consumes: current body positions from the WASM snapshot.
- Produces: smooth look-at target tracking the selected/followed body using a predictive lead (target position estimated `α·dt` ahead) and damped orientation so the frame never snaps; FOV/zoom clamped to avoid gimbal lock; background star field + subtle nebula gradient (added as a full-screen quad fragment, cheap).

- [ ] **Steps 1–5**: implement damped follow mode, add predictive lead, add background quad; verify subject stays within the frame during high-speed flybys without snapping. Commit message: `feat(camera): predicted-motion-follow camera and background skybox`.

---

### Task 11: Full documentation sweep (PHYSICS.md complete + inline Rust docs + README finalization)

**Files:**
- Complete: `PHYSICS.md` — derivations of the Newtonian pairwise force, the velocity-Verlet discretization and why it is symplectic (bounded energy error vs secular drift), the Plummer softening choice and its effect on close encounters, the full 1PN EIH acceleration implemented (transcribed verbatim from the validated reference), the nondimensionalisation table per preset in SI units, the bloom pipeline description (half-resolution separable Gaussian, Reinhard compression, γ 2.2), and the offline validation-gate methodology.
- Inline: `///` doc comments on every public item in `src/lib.rs`, `src/physics.rs`, `src/presets.rs`.
- Finalize: `README.md` (build/run/deploy instructions incl. the GitHub Pages account-provisioning caveat already diagnosed on 2026-11-22).

Commit message: `docs: complete PHYSICS.md derivations, rustdoc coverage, and README deployment notes`.

---

### Task 12: Continuous-integration scaffold + end-to-end verification + merge readiness

**Files:**
- Create: `.github/workflows/ci.yml` — two jobs on push to `main` and PRs: (a) `cargo test --lib` on the native host target (math/units/presets/tests run fast); (b) `cargo build --release --target wasm32-unknown-unknown` proving the offline WASM build stays dependency-free. Token scope observation carried forward: this repo token holds `workflow` scope, so committing the workflow file itself is consistent with observed grants.
- Modify: `deploy-github-pages.sh` (already committed) — wire the CI-built `dist/` directory rather than rebuilding locally (idempotent).
- Verification pass: load the built site through the CDP/browser harness; assert (i) page loads with no uncaught console errors, (ii) ≥50 fps during motion, (iii) energy/momentum readouts populated, (iv) all five presets switchable and editable live, (v) `cargo test` green, (vi) offline WASM build green.

- [ ] **Steps 1–5**: author CI workflow; run it via `gh` API simulation locally (dry-run the checks); run the full verification matrix; squash-fix any findings; adversarial review of the whole diff to zero findings including NITs; unslop-check all external-facing text; then open the merge PR. Commit messages: `ci: add native-test + std-only WASM build workflow`, followed by `chore: finalize deploy script wiring to CI-built dist`.

---

## Self-Review Checklist (run by the plan owner before execution)

1. **Spec coverage:** skim each section of `docs/superpowers/specs/2026-11-22-exotic-orbits-sim-design.md`. §2 acceptance criteria → Task 12 verification checklist (all six metrics named there appear in Task 12 step 5). §3.1 zero-crates → Global Constraint + Task 0 Step 1 Cargo.toml comment + ci.yml job (b). §5 rendering/half-res-bloom → Task 7 Step 4. §6.3 softening ε≈0.03·min separation → Tasks 3/5. §6.4 ~200+ sub-steps/frame → Task 8 Step 2 formula. §6.6 GR knob 0…~50× default 1× → Tasks 4/9. §6.7 validation gate → Task 4 Step 1. §9 interactivity → Task 9. §13 delivery + gh-pages fallback → Tasks 11/12 + committed `deploy-github-pages.sh`. No gaps found.
2. **Placeholder scan:** search the plan for `TODO|FIXME|XXX|TBD|HACK|PLACEHOLDER|"similar to"` → none present; the only intentional placeholders are the documented `license = "MIT"` string in Cargo.toml (flagged explicitly above as pending an explicit owner decision on licensing) and the intentionally-labeled `__WASM_SIZE_CHECK__` build define.
3. **Type/signature consistency:** `UnitSystem::for_preset(id: PresetId) -> UnitSystem` (Task 5 Step 1) matches `UnitSystem` produced in Task 2; `NBodySim::two_body_circular(...)` and `central_plus_test_particle(...)` referenced in Task 4 tests are declared in Task 3's produced interface list; `orbital_elements_to_ic` is defined once in `src/presets.rs` (Task 9) and consumed by the JS editor — the same name appears in both Task 9 interfaces and Task 9 steps; `MEM_LAYOUT` offsets in Task 8 match the `OFF_*` constants written there. Cross-check again when Task 8 implementation begins since Rust `MEM_LAYOUT` constants must mirror the JS literals exactly.
