// @ts-check

/**
 * Stages the pinned Apple Silicon Node Runtime for the Flutter macOS bundle.
 *
 * The generated asset tree is ignored by Git. A macOS build must run this
 * script after the Runtime Core is compiled so the app never resolves Node
 * from PATH or executes an unstaged entrypoint.
 */
import { access, chmod, copyFile, cp, mkdir, rm } from "node:fs/promises";
import { dirname, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const nodeRuntimeRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const runtimePackagesRoot = resolve(nodeRuntimeRoot, "..");
const sourceNodeDirectory = resolve(
  nodeRuntimeRoot,
  "tools",
  "node-v24.16.0-darwin-arm64",
);
const sourceNodeExecutable = resolve(sourceNodeDirectory, "bin", "node");
const sourceNodeLicense = resolve(sourceNodeDirectory, "LICENSE");
const sourceNpmPackage = resolve(
  sourceNodeDirectory,
  "lib",
  "node_modules",
  "npm",
);
const sourceDist = resolve(nodeRuntimeRoot, "dist");
const sourceEntrypoint = resolve(sourceDist, "cli.js");
const assetsRoot = resolve(
  runtimePackagesRoot,
  "mgread_plugin_runtime",
  "assets",
  "runtime",
  "macos-arm64",
);
const stagedNodeDirectory = resolve(assetsRoot, "node");
const stagedNodeExecutable = resolve(stagedNodeDirectory, "MgReadNode");
const stagedBuildNodeExecutable = resolve(stagedNodeDirectory, "node");
const stagedNodeLicense = resolve(stagedNodeDirectory, "LICENSE");
const stagedNpmPackage = resolve(stagedNodeDirectory, "node_modules", "npm");
const stagedDist = resolve(assetsRoot, "dist");
const stagedNodeModules = resolve(stagedNodeDirectory, "node_modules");
const stagedDefaultPluginsDirectory = resolve(assetsRoot, "default-plugins");

function assertInsideRuntimePackages(candidatePath) {
  const pathFromRoot = relative(runtimePackagesRoot, candidatePath);
  if (
    pathFromRoot === "" ||
    pathFromRoot.startsWith("..") ||
    pathFromRoot.includes(":")
  ) {
    throw new Error("Refusing to stage Runtime assets outside the packages directory.");
  }
}

async function requireReadable(candidatePath, label) {
  try {
    await access(candidatePath);
  } catch {
    throw new Error(`Cannot stage macOS Runtime: ${label} is unavailable.`);
  }
}

for (const candidatePath of [
  sourceNodeDirectory,
  sourceNodeExecutable,
  sourceNodeLicense,
  sourceDist,
  sourceEntrypoint,
  assetsRoot,
  stagedNodeDirectory,
  stagedNodeExecutable,
  stagedBuildNodeExecutable,
  stagedNodeLicense,
  stagedNpmPackage,
  stagedDist,
  stagedNodeModules,
  stagedDefaultPluginsDirectory,
]) {
  assertInsideRuntimePackages(candidatePath);
}
await requireReadable(sourceNodeExecutable, "the exact bundled Node executable");
await requireReadable(sourceNodeLicense, "the bundled Node license");
await requireReadable(sourceNpmPackage, "the bundled npm CLI");
await requireReadable(sourceDist, "the compiled Runtime entrypoint");
await requireReadable(sourceEntrypoint, "the compiled Runtime main script");

await rm(stagedNodeDirectory, { force: true, recursive: true });
await rm(stagedDist, { force: true, recursive: true });
await rm(stagedNodeModules, { force: true, recursive: true });
await rm(stagedDefaultPluginsDirectory, { force: true, recursive: true });
await mkdir(stagedNodeDirectory, { recursive: true });
await copyFile(sourceNodeExecutable, stagedNodeExecutable);
await chmod(stagedNodeExecutable, 0o755);
// npm lifecycle shims invoke `node` by name. Keep the exact pinned executable
// beside the Runtime binary so development builds never resolve ambient Node.
await copyFile(sourceNodeExecutable, stagedBuildNodeExecutable);
await chmod(stagedBuildNodeExecutable, 0o755);
await copyFile(sourceNodeLicense, stagedNodeLicense);
await cp(sourceNpmPackage, stagedNpmPackage, { recursive: true });
await cp(sourceDist, stagedDist, { recursive: true });

process.stdout.write(
  "Staged the pinned macOS ARM64 Runtime asset bundle with its npm CLI; plugin projects remain external.\n",
);
