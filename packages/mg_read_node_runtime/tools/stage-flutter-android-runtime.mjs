// Stages the built Node Runtime for Flutter Android and fingerprints its files
// so an updated APK replaces stale extracted Runtime assets on the device.
import { createHash } from "node:crypto";
import { cp, mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { dirname, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

async function directoryFingerprint(root) {
  const files = [];

  async function collect(directory) {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const file = resolve(directory, entry.name);
      if (entry.isDirectory()) {
        await collect(file);
      } else if (entry.isFile()) {
        files.push(file);
      }
    }
  }

  await collect(root);
  const hash = createHash("sha256");
  for (const file of files.sort()) {
    hash.update(relative(root, file).replaceAll("\\", "/"));
    hash.update("\0");
    hash.update(await readFile(file));
    hash.update("\0");
  }
  return hash.digest("hex");
}

const runtimeRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const packageJson = JSON.parse(
  await readFile(resolve(runtimeRoot, "package.json"), "utf8"),
);
const distRoot = resolve(runtimeRoot, "dist");
const assetRoot = resolve(
  runtimeRoot,
  "../mgread_plugin_runtime/assets/runtime/android",
);
const assetDist = resolve(assetRoot, "dist");
const assetNodeModules = resolve(assetRoot, "node_modules");
const defaultPluginsRoot = resolve(assetRoot, "default-plugins");

await rm(assetDist, { force: true, recursive: true });
await rm(assetNodeModules, { force: true, recursive: true });
await rm(defaultPluginsRoot, { force: true, recursive: true });
await mkdir(assetRoot, { recursive: true });
await cp(distRoot, assetDist, { recursive: true });
const assetFingerprint = await directoryFingerprint(assetDist);
const runtimeAssetVersion = `${packageJson.version}-${assetFingerprint}`;
await writeFile(resolve(assetRoot, "runtime-version.txt"), `${runtimeAssetVersion}\n`);

process.stdout.write(`Staged Android Runtime assets for ${runtimeAssetVersion}.\n`);
