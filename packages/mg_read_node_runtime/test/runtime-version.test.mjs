import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import {
  expectedNodeVersion,
  nodeVersionByBackend,
  protocolVersion,
  runtimeCompatibility,
} from "../dist/index.js";

const runtimeRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const flutterPubspec = resolve(
  runtimeRoot,
  "../mgread_plugin_runtime/pubspec.yaml",
);
async function runtimeAssetEntries() {
  const pubspec = await readFile(flutterPubspec, "utf8");
  return [...pubspec.matchAll(/^\s+- (assets\/runtime\/[^\r\n]+)$/gm)]
    .map((match) => match[1]);
}

// The fixture verifies that runtime metadata and desktop protocol expectations
// are kept in lockstep without starting a child process.
const desktopFixture = JSON.parse(
  await readFile(
    new URL("../protocol/fixtures/standard-node-plugin-v1.json", import.meta.url),
    "utf8",
  ),
);

test("loads backend-specific Runtime metadata through pinned Node ESM", async () => {
  assert.equal(process.versions.node, expectedNodeVersion);
  assert.equal(process.version, "v" + expectedNodeVersion);
  assert.equal(protocolVersion, desktopFixture.protocolVersion);
  assert.equal(runtimeCompatibility.runtime, desktopFixture.runtimeVersion);
  assert.deepEqual(runtimeCompatibility.android.nodeAbis, [
    "arm64-v8a",
    "x86_64",
  ]);
  assert.equal(runtimeCompatibility.android.javetNode, nodeVersionByBackend.androidJavet);
  assert.equal(runtimeCompatibility.android.processNode, nodeVersionByBackend.androidProcess);
  assert.equal(runtimeCompatibility.desktop.windows.node, nodeVersionByBackend.windows);
  assert.equal(runtimeCompatibility.desktop.macos.node, nodeVersionByBackend.macos);
  const recorded = JSON.parse(await readFile(new URL("../protocol/compatibility.json", import.meta.url), "utf8"));
  assert.equal(recorded.runtime.javetAndroid.node, nodeVersionByBackend.androidJavet);
  assert.equal(recorded.runtime.processNode, nodeVersionByBackend.androidProcess);
  assert.equal(recorded.desktop.windows.node, nodeVersionByBackend.windows);
  assert.equal(recorded.desktop.macos.node, nodeVersionByBackend.macos);
});

test("Flutter package declares Runtime assets and excludes development npm", async () => {
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
  assert.ok(!assetEntries.some((entry) =>
    entry.includes("/node/node_modules/npm/")));
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
