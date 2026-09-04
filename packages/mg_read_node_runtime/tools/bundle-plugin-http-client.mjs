// Bundles the one CommonJS-backed Undici boundary into Runtime-owned ESM so
// desktop Node and Android Javet load the same self-contained implementation.
import { rename, rm } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { build } from "esbuild";

const runtimeRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const entrypoint = resolve(runtimeRoot, "dist", "plugin-http-client.js");
const bundled = resolve(runtimeRoot, "dist", ".plugin-http-client.bundled.js");

await build({
  banner: {
    js: 'import { createRequire as __mgreadCreateRequire } from "node:module"; const require = __mgreadCreateRequire(import.meta.url);',
  },
  bundle: true,
  entryPoints: [entrypoint],
  format: "esm",
  outfile: bundled,
  platform: "node",
  target: "node24",
});
await rename(bundled, entrypoint);
await rm(`${entrypoint}.map`, { force: true });
