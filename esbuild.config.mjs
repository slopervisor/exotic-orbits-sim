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
import { cpSync } from "node:fs";
cpSync("target/wasm32-unknown-unknown/release/exotic_orbits_sim.wasm", "dist/assets/app.wasm");
