import { cp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const runtimeRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const packageJson = JSON.parse(
  await readFile(resolve(runtimeRoot, "package.json"), "utf8"),
);
const distRoot = resolve(runtimeRoot, "dist");
const assetRoot = resolve(
  runtimeRoot,
  "packages/mgread_plugin_runtime/assets/runtime/android",
);
const assetDist = resolve(assetRoot, "dist");

await rm(assetDist, { force: true, recursive: true });
await mkdir(assetRoot, { recursive: true });
await cp(distRoot, assetDist, { recursive: true });
await writeFile(resolve(assetRoot, "runtime-version.txt"), `${packageJson.version}\n`);

process.stdout.write(`Staged Android Runtime assets for ${packageJson.version}.\n`);
