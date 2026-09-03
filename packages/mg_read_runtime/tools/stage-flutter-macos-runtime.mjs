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

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const sourceNodeDirectory = resolve(
  repositoryRoot,
  "tools",
  "node-v24.16.0-darwin-arm64",
);
const sourceNodeExecutable = resolve(sourceNodeDirectory, "bin", "node");
const sourceNodeLicense = resolve(sourceNodeDirectory, "LICENSE");
const sourceDist = resolve(repositoryRoot, "dist");
const sourceEntrypoint = resolve(sourceDist, "cli.js");
const assetsRoot = resolve(
  repositoryRoot,
  "packages",
  "mgread_plugin_runtime",
  "assets",
  "runtime",
  "macos-arm64",
);
const stagedNodeDirectory = resolve(assetsRoot, "node");
const stagedNodeExecutable = resolve(stagedNodeDirectory, "MgReadNode");
const stagedNodeLicense = resolve(stagedNodeDirectory, "LICENSE");
const stagedDist = resolve(assetsRoot, "dist");
const stagedDefaultPluginsDirectory = resolve(assetsRoot, "default-plugins");

function assertInsideRepository(candidatePath) {
  const pathFromRoot = relative(repositoryRoot, candidatePath);
  if (
    pathFromRoot === "" ||
    pathFromRoot.startsWith("..") ||
    pathFromRoot.includes(":")
  ) {
    throw new Error("Refusing to stage Runtime assets outside this repository.");
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
  stagedNodeLicense,
  stagedDist,
  stagedDefaultPluginsDirectory,
]) {
  assertInsideRepository(candidatePath);
}
await requireReadable(sourceNodeExecutable, "the exact bundled Node executable");
await requireReadable(sourceNodeLicense, "the bundled Node license");
await requireReadable(sourceDist, "the compiled Runtime entrypoint");
await requireReadable(sourceEntrypoint, "the compiled Runtime main script");

await rm(stagedNodeDirectory, { force: true, recursive: true });
await rm(stagedDist, { force: true, recursive: true });
await rm(stagedDefaultPluginsDirectory, { force: true, recursive: true });
await mkdir(stagedNodeDirectory, { recursive: true });
await copyFile(sourceNodeExecutable, stagedNodeExecutable);
await chmod(stagedNodeExecutable, 0o755);
await copyFile(sourceNodeLicense, stagedNodeLicense);
await cp(sourceDist, stagedDist, { recursive: true });

process.stdout.write(
  "Staged the pinned macOS ARM64 Runtime asset bundle; plugin projects remain external.\n",
);
