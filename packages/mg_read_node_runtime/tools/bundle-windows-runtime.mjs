/** Produces one Windows release entrypoint from the tested Core build.
 * Keeps Node builtins external and source imports dynamic; both pinned engines
 * execute the same ESM bundle. Debug maps stay in the ignored compiler output,
 * never in Flutter assets. The inspector's three static files remain adjacent.
 */
import { build } from "esbuild";
import { copyFile, mkdir, writeFile } from "node:fs/promises";
import { dirname, resolve, relative } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");

export async function createWindowsRuntimeBundle() {
  const result = await build({
    entryPoints: [resolve(root, "dist/cli.js")],
    outfile: resolve(root, "dist/windows-release/cli.js"),
    bundle: true,
    format: "esm",
    platform: "node",
    target: "node24",
    minify: true,
    sourcemap: "external",
    legalComments: "eof",
    write: false,
    banner: { js: 'import { createRequire as __releaseRequire } from "node:module"; const require = __releaseRequire(import.meta.url);' },
  });
  return {
    code: result.outputFiles.find(file => file.path.endsWith("cli.js")).contents,
    map: result.outputFiles.find(file => file.path.endsWith("cli.js.map")).contents,
  };
}

export async function stageWindowsRuntimeCode(destination) {
  const expected = resolve(root, "../mgread_plugin_runtime/assets/runtime/windows-x64/dist");
  if (relative(expected, resolve(destination)) !== "") throw new Error("Unexpected Windows Runtime destination.");
  const { code, map } = await createWindowsRuntimeBundle();
  await mkdir(resolve(destination, "debug-ui"), { recursive: true });
  await writeFile(resolve(destination, "cli.js"), code);
  const symbols = resolve(root, "dist/windows-release");
  await mkdir(symbols, { recursive: true });
  await writeFile(resolve(symbols, "cli.js.map"), map);
  for (const name of ["app.css", "app.js", "index.html"]) {
    await copyFile(resolve(root, "dist/debug-ui", name), resolve(destination, "debug-ui", name));
  }
}
