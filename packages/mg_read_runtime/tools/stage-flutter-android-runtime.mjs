import { copyFile, cp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
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
const defaultPluginsRoot = resolve(assetRoot, "default-plugins");
const sourcePluginRoot = resolve(runtimeRoot, "..", "..", "plugins", "sources");
const bundledPlugins = [
  ["aisishuwu", "org.mgread.aisishuwu-0.1.0.mgplugin"],
  ["mgread-discovery-demo", "org.mgread.discovery-demo-0.1.0.mgplugin"],
];

await rm(assetDist, { force: true, recursive: true });
await rm(defaultPluginsRoot, { force: true, recursive: true });
await mkdir(assetRoot, { recursive: true });
await mkdir(defaultPluginsRoot, { recursive: true });
await cp(distRoot, assetDist, { recursive: true });
for (const [sourceId, artifactName] of bundledPlugins) {
  await copyFile(
    resolve(sourcePluginRoot, sourceId, "artifacts", artifactName),
    resolve(defaultPluginsRoot, artifactName),
  );
}
await writeFile(resolve(assetRoot, "runtime-version.txt"), `${packageJson.version}\n`);

process.stdout.write(`Staged Android Runtime assets for ${packageJson.version}.\n`);
