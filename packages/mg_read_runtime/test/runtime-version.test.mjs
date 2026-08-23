import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";
import test from "node:test";

import {
  expectedNodeVersion,
  protocolVersion,
  runtimeCompatibility,
} from "../dist/index.js";

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
  const pubspec = await readFile(
    new URL(
      "../packages/mgread_plugin_runtime/pubspec.yaml",
      import.meta.url,
    ),
    "utf8",
  );
  const assetEntries = [...pubspec.matchAll(/^\s+- (assets\/runtime\/[^\r\n]+)$/gm)]
    .map((match) => match[1]);

  assert.deepEqual(assetEntries, [
    "assets/runtime/android/runtime-version.txt",
    "assets/runtime/android/dist/",
    "assets/runtime/android/dist/diagnostics/",
    "assets/runtime/windows-x64/node/",
    "assets/runtime/windows-x64/dist/",
    "assets/runtime/windows-x64/dist/diagnostics/",
  ]);
  assert.ok(!assetEntries.includes("assets/runtime/android/"));
  assert.ok(!assetEntries.includes("assets/runtime/windows-x64/"));
});

test("clean build excludes the deleted legacy template fixture", async () => {
  await assert.rejects(
    access(new URL("../dist/template-plugin-fixture.js", import.meta.url)),
    (error) => error?.code === "ENOENT",
  );
});
