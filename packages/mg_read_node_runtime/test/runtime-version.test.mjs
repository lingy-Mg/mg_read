import assert from "node:assert/strict";
import { access, readFile, readdir } from "node:fs/promises";
import { dirname, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import {
  expectedNodeVersion,
  protocolVersion,
  runtimeCompatibility,
} from "../dist/index.js";

const runtimeRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const flutterPubspec = resolve(
  runtimeRoot,
  "../mgread_plugin_runtime/pubspec.yaml",
);
const pinnedWindowsNpmRoot = resolve(
  runtimeRoot,
  "tools/node-v24.16.0-win-x64/node_modules/npm",
);
const windowsNpmAssetPrefix =
  "assets/runtime/windows-x64/node/node_modules/npm/";

async function runtimeAssetEntries() {
  const pubspec = await readFile(flutterPubspec, "utf8");
  return [...pubspec.matchAll(/^\s+- (assets\/runtime\/[^\r\n]+)$/gm)]
    .map((match) => match[1]);
}

async function directoriesContainingFiles(root) {
  const directories = [];

  async function collect(directory) {
    const entries = await readdir(directory, { withFileTypes: true });
    if (entries.some((entry) => entry.isFile() || entry.isSymbolicLink())) {
      const pathFromRoot = relative(root, directory).split(sep).join("/");
      directories.push(pathFromRoot.length === 0 ? "" : `${pathFromRoot}/`);
    }
    await Promise.all(
      entries
        .filter((entry) => entry.isDirectory())
        .map((entry) => collect(resolve(directory, entry.name))),
    );
  }

  await collect(root);
  return directories;
}

// The fixture verifies that runtime metadata and desktop protocol expectations
// are kept in lockstep without starting a child process.
const desktopFixture = JSON.parse(
  await readFile(
    new URL("../protocol/fixtures/standard-node-plugin-v1.json", import.meta.url),
    "utf8",
  ),
);

test("loads Runtime metadata through Node 24 ESM", () => {
  assert.equal(process.versions.node, expectedNodeVersion);
  assert.equal(process.version, "v" + expectedNodeVersion);
  assert.equal(protocolVersion, desktopFixture.protocolVersion);
  assert.equal(runtimeCompatibility.runtime, desktopFixture.runtimeVersion);
  assert.deepEqual(runtimeCompatibility.android.nodeAbis, [
    "arm64-v8a",
    "x86_64",
  ]);
});

test("Flutter package declares every nested platform Runtime asset directory", async () => {
  const assetEntries = await runtimeAssetEntries();

  for (const requiredEntry of [
    "assets/runtime/android/runtime-version.txt",
    "assets/runtime/android/dist/",
    "assets/runtime/android/dist/debug-ui/",
    "assets/runtime/windows-x64/node/",
    "assets/runtime/windows-x64/dist/",
    "assets/runtime/windows-x64/dist/debug-ui/",
    "assets/runtime/macos-arm64/node/",
    "assets/runtime/macos-arm64/dist/",
    "assets/runtime/macos-arm64/dist/debug-ui/",
  ]) {
    assert.ok(assetEntries.includes(requiredEntry), requiredEntry);
  }
  assert.ok(!assetEntries.includes("assets/runtime/android/"));
  assert.ok(!assetEntries.includes("assets/runtime/windows-x64/"));
  assert.ok(!assetEntries.includes("assets/runtime/macos-arm64/"));
});

test("Flutter package declares exactly the pinned Windows npm asset directories containing files", async () => {
  const declaredDirectories = (await runtimeAssetEntries())
    .filter((entry) => entry.startsWith(windowsNpmAssetPrefix))
    .toSorted();
  const expectedDirectories = (await directoriesContainingFiles(
    pinnedWindowsNpmRoot,
  ))
    .map((directory) => `${windowsNpmAssetPrefix}${directory}`)
    .toSorted();

  assert.deepEqual(declaredDirectories, expectedDirectories);
});

test("Android Runtime asset marker includes its staged content fingerprint", async () => {
  const packageJson = JSON.parse(
    await readFile(new URL("../package.json", import.meta.url), "utf8"),
  );
  const marker = await readFile(
    new URL(
      "../../mgread_plugin_runtime/assets/runtime/android/runtime-version.txt",
      import.meta.url,
    ),
    "utf8",
  );

  assert.match(
    marker,
    new RegExp(`^${packageJson.version.replaceAll(".", "\\.")}-[a-f0-9]{64}\\n$`),
  );
});

test("clean build excludes the deleted legacy template fixture", async () => {
  await assert.rejects(
    access(new URL("../dist/template-plugin-fixture.js", import.meta.url)),
    (error) => error?.code === "ENOENT",
  );
});
