// @ts-check

import { access, copyFile, cp, mkdir, rm } from "node:fs/promises";
import { dirname, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

/** Node.js Runtime root derived from this script, never from the shell working directory. */
const nodeRuntimeRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const runtimePackagesRoot = resolve(nodeRuntimeRoot, "..");
const sourceNodeDirectory = resolve(
  nodeRuntimeRoot,
  "tools",
  "node-v24.16.0-win-x64",
);
const sourceNodeExecutable = resolve(sourceNodeDirectory, "node.exe");
const sourceNodeLicense = resolve(sourceNodeDirectory, "LICENSE");
const sourceDist = resolve(nodeRuntimeRoot, "dist");
const sourceEntrypoint = resolve(sourceDist, "cli.js");
const assetsRoot = resolve(
  runtimePackagesRoot,
  "mgread_plugin_runtime",
  "assets",
  "runtime",
  "windows-x64",
);
const stagedNodeDirectory = resolve(assetsRoot, "node");
const stagedNodeExecutable = resolve(stagedNodeDirectory, "MgReadNode.exe");
const stagedNodeLicense = resolve(stagedNodeDirectory, "LICENSE");
const stagedDist = resolve(assetsRoot, "dist");
const stagedNodeModules = resolve(stagedNodeDirectory, "node_modules");
const stagedDefaultPluginsDirectory = resolve(assetsRoot, "default-plugins");

/**
 * Refuses any destructive staging target outside this checked-out Runtime tree.
 *
 * The staging operation removes only deterministic package assets, but the
 * containment check remains mandatory before every `rm` or `cp` target.
 *
 * @param {string} candidatePath Absolute path to validate against runtimePackagesRoot.
 */
function assertInsideRuntimePackages(candidatePath) {
  const pathFromRoot = relative(runtimePackagesRoot, candidatePath);
  if (pathFromRoot === "" || pathFromRoot.startsWith("..") || pathFromRoot.includes(":")) {
    throw new Error("Refusing to stage Runtime assets outside the packages directory.");
  }
}

/**
 * Converts a raw filesystem failure into a stable build-time message.
 *
 * @param {string} candidatePath Required Runtime source file or directory.
 * @param {string} label Human-readable fixed label; never an ambient path.
 */
async function requireReadable(candidatePath, label) {
  try {
    await access(candidatePath);
  } catch {
    throw new Error(`Cannot stage Windows Runtime: ${label} is unavailable.`);
  }
}

assertInsideRuntimePackages(sourceNodeDirectory);
assertInsideRuntimePackages(sourceNodeExecutable);
assertInsideRuntimePackages(sourceNodeLicense);
assertInsideRuntimePackages(sourceDist);
assertInsideRuntimePackages(sourceEntrypoint);
assertInsideRuntimePackages(assetsRoot);
assertInsideRuntimePackages(stagedNodeDirectory);
assertInsideRuntimePackages(stagedNodeExecutable);
assertInsideRuntimePackages(stagedNodeLicense);
assertInsideRuntimePackages(stagedDist);
assertInsideRuntimePackages(stagedNodeModules);
assertInsideRuntimePackages(stagedDefaultPluginsDirectory);
await requireReadable(sourceNodeDirectory, "the exact bundled Node distribution");
await requireReadable(sourceNodeExecutable, "the exact bundled Node executable");
await requireReadable(sourceNodeLicense, "the bundled Node license");
await requireReadable(sourceDist, "the compiled Runtime entrypoint");
await requireReadable(sourceEntrypoint, "the compiled Runtime main script");

// These deterministic paths are output of the pinned toolchain and are
// ignored by Git. The asset-root marker is intentionally preserved so an empty
// source checkout still passes Flutter asset discovery before staging.
await rm(stagedNodeDirectory, { force: true, recursive: true });
await rm(stagedDist, { force: true, recursive: true });
await rm(stagedNodeModules, { force: true, recursive: true });
await rm(stagedDefaultPluginsDirectory, { force: true, recursive: true });
await mkdir(assetsRoot, { recursive: true });
await mkdir(stagedNodeDirectory, { recursive: true });
await copyFile(sourceNodeExecutable, stagedNodeExecutable);
await copyFile(sourceNodeLicense, stagedNodeLicense);
await cp(sourceDist, stagedDist, { recursive: true });

process.stdout.write("Staged the pinned Windows Node executable and Runtime assets; npm remains development-only.\n");
