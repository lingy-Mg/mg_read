import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
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
