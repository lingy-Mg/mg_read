import assert from "node:assert/strict";
import { access, readFile, readdir, stat } from "node:fs/promises";
import { dirname, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import test from "node:test";

const executeFile = promisify(execFile);
const runtimeRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");

async function directoriesContainingFiles(root) {
  const directories = [];
  const entries = await readdir(root, { withFileTypes: true });
  if (entries.some((entry) => entry.isFile() || entry.isSymbolicLink())) {
    directories.push(root);
  }
  await Promise.all(entries.filter((entry) => entry.isDirectory()).map(async (entry) => {
    directories.push(...await directoriesContainingFiles(resolve(root, entry.name)));
  }));
  return directories;
}

test("macOS staging uses the pinned executable and npm CLI", async () => {
  await executeFile(
    process.execPath,
    ["tools/stage-flutter-macos-runtime.mjs"],
    { cwd: runtimeRoot },
  );
  const source = resolve(
    runtimeRoot,
    "tools/node-v24.16.0-darwin-arm64/bin/node",
  );
  const staged = resolve(
    runtimeRoot,
    "../mgread_plugin_runtime/assets/runtime/macos-arm64/node/MgReadNode",
  );
  const stagedBuildNode = resolve(
    runtimeRoot,
    "../mgread_plugin_runtime/assets/runtime/macos-arm64/node/node",
  );
  const stagedNpmCli = resolve(
    runtimeRoot,
    "../mgread_plugin_runtime/assets/runtime/macos-arm64/node/node_modules/npm/bin/npm-cli.js",
  );
  const stagedNpmPackageRoot = resolve(stagedNpmCli, "..", "..");
  const entrypoint = resolve(
    runtimeRoot,
    "../mgread_plugin_runtime/assets/runtime/macos-arm64/dist/cli.js",
  );
  await Promise.all([
    access(staged),
    access(stagedBuildNode),
    access(stagedNpmCli),
    access(entrypoint),
  ]);
  const [sourceBytes, stagedBytes, stagedBuildNodeBytes, stagedStat, stagedBuildNodeStat, sourceNpmPackage, stagedNpmPackage] = await Promise.all([
    readFile(source),
    readFile(staged),
    readFile(stagedBuildNode),
    stat(staged),
    stat(stagedBuildNode),
    readFile(resolve(runtimeRoot, "tools/node-v24.16.0-darwin-arm64/lib/node_modules/npm/package.json")),
    readFile(resolve(stagedNpmPackageRoot, "package.json")),
  ]);
  assert.deepEqual(stagedBytes, sourceBytes);
  assert.deepEqual(stagedBuildNodeBytes, sourceBytes);
  assert.deepEqual(stagedNpmPackage, sourceNpmPackage);
  assert.notEqual(stagedStat.mode & 0o111, 0);
  assert.notEqual(stagedBuildNodeStat.mode & 0o111, 0);
  const { stdout } = await executeFile(staged, ["--version"]);
  assert.equal(stdout.trim(), "v24.16.0");
  const npm = await executeFile(staged, [stagedNpmCli, "--version"]);
  assert.equal(npm.stdout.trim(), "11.13.0");

  const pubspec = await readFile(
    resolve(runtimeRoot, "../mgread_plugin_runtime/pubspec.yaml"),
    "utf8",
  );
  const declaredAssets =
    [...pubspec.matchAll(/^\s+- (assets\/runtime\/[^\r\n]+)$/gm)]
      .map((match) => match[1])
      .filter((asset) => asset.startsWith("assets/runtime/macos-arm64/node/node_modules/npm/"))
      .toSorted();
  const expectedAssets = (await directoriesContainingFiles(stagedNpmPackageRoot))
    .map((directory) => {
      const nested = relative(stagedNpmPackageRoot, directory).split("\\").join("/");
      return `assets/runtime/macos-arm64/node/node_modules/npm/${nested === "" ? "" : `${nested}/`}`;
    })
    .toSorted();
  assert.deepEqual(declaredAssets, expectedAssets);
});
