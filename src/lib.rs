//! Exotic Orbits Simulator — a std-only Rust `cdylib` compiled to
//! `wasm32-unknown-unknown`.
//!
//! All physics calculations (Newtonian N-body gravity + the first
//! post-Newtonian general-relativity correction, velocity-Verlet
//! symplectic integration, Plummer softening and trail buffering) live on
//! this side of the WebAssembly boundary and are exposed to the host JS via
//! C-ABI `extern "C"` entry points operating on a shared `WebAssembly.Memory`.
//!
//! Module roots are declared incrementally across the implementation tasks
//! (Task 1 `math`, Task 2 `units`, Task 3 `physics`, …), keeping each task's
//! crate compiling cleanly from the first commit. See the project layout in
//! `docs/superpowers/specs/2026-11-22-exotic-orbits-sim-design.md` §4.

// NOTE: `wasm32-unknown-unknown` is a foreign-ABI target, so `std` is not linked
// into our `cdylib` automatically. Declaring `extern crate std` opts the crate
// back into linking the standard library, which also provides the `panic_impl`
// lang item. Without this line the release WASM build fails to link. Nothing in
// this module changes the simulation code path; it exists so the binary links.
extern crate std;
