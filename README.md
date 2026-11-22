# exotic-orbits-sim

Interactive showcase of **exotic few-body gravitational dynamics**: the figure-eight
three-body solution, a Klemperer rosette, Lagrange's equilateral-triangle point, and
eccentric relativistic flybys — rendered in real time with shaded spheres, orbital trails
and bloom post-processing.

The physics runs in **Rust compiled to WebAssembly**; the graphics run in raw **WebGL2**,
driven by host JavaScript. Every calculation is documented in [`PHYSICS.md`](PHYSICS.md).

## Live version

Public demo hosted via GitHub Pages (deployment procedure below):

> https://slopervisor.github.io/exotic-orbits-sim/

## Stack

| Layer | Technology |
|-------|-----------|
| Physics engine | Rust `cdylib` targeting `wasm32-unknown-unknown` (**zero external crates**) |
| Boundary | C-ABI exports over a shared `WebAssembly.Memory`; JS owns the rAF loop |
| Rendering | Hand-written WebGL2 (instanced icospheres, Blinn-Phong, multi-pass bloom, trail lines) |
| Build | `cargo` (WASM) + esbuild (base64-inlines the `.wasm` into one JS bundle) |

See the design doc at `docs/superpowers/specs/2026-11-22-exotic-orbits-sim-design.md`.

## Prerequisites

- Rust toolchain with the WASM target:
  ```bash
  rustup toolchain install stable
  rustup component add rust-src
  rustup target add wasm32-unknown-unknown
  ```
- Node.js 18+ and npm (for esbuild and the static dev server).

Building the WASM itself needs **no network access** afterwards — the build uses no registry
crates (hand-written math and WebGL glue).

## Build

```bash
# 1. Compile the physics engine to WebAssembly (release profile)
cargo build --release --target wasm32-unknown-unknown

# 2. Bundle host JS + the WASM (base64-inlined) into dist/
npx esbuild main.js \
  --bundle \
  --format=esm \
  --loader:.wasm;base64 \
  --outfile=dist/assets/app.js \
  --define:__WASM_PATH__="'./app.wasm'"
cp target/wasm32-unknown-unknown/release/exotic_orbits_sim.wasm dist/assets/app.wasm
```

(The exact esbuild flags live in the build script once the project is initialised.)

## Run locally

```bash
npx serve dist        # or any static server; WASM must be served with MIME application/wasm
```

Open http://localhost:<port> .

## Test

```bash
# unit tests (run offline)
cargo test --target wasm32-unknown-unknown

# headless verification: load the page, assert 50+ fps and a clean console
# (see docs/superpowers/specs/...-design.md §2 acceptance criteria)
```

## Deploy to GitHub Pages

```bash
chmod +x deploy-github-pages.sh
./deploy-github-pages.sh                 # publishes the built dist/ to a gh-pages branch
./deploy-github-pages.sh --dry-run       # validate the steps without mutating anything
```

Requirements: a `GITHUB_TOKEN` or `GH_TOKEN` environment variable holding a PAT with the `repo`
scope. The script never prints or persists the token.

Two paths are attempted automatically:

1. Configure the repository's advanced Pages source through `gh` (only works where the account
   permits it);
2. Fall back to pushing the built site onto a `gh-pages` branch, which GitHub auto-publishes at
   `https://<owner>.github.io/<repo>/`.

Known limitation (2026-11-22): the account behind this repo returned HTTP 404 stably on the REST
`PUT /repos/{owner}/{repo}/pages` endpoint while GitHub's `/meta` endpoint reports the Pages
service healthy — treated as an account-level provisioning gate. If automatic publication does not
come up, enable it manually: **Settings ▸ Pages ▸ Source → `gh-pages` branch, `/root`**.

## Project layout

```
src/
  math.rs          vec3/mat4/quaternion arithmetic
  units.rs         nondimensionalisation + SI conversion tables per preset
  physics.rs       Newtonian N-body + 1PN GR acceleration, velocity-Verlet integrator
  presets.rs       exact initial conditions for each showcased configuration
  render_gl.rs     WebGL2 program/VBO/VAO management
  app.rs           rAF driver + UI-message dispatch
assets/shaders/    GLSL vertex/fragment sources
PHYSICS.md         full derivations of the mechanics, integrator and rendering pipeline
```

