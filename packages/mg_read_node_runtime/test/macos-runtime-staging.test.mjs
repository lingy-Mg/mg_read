import assert from "node:assert/strict";
import { access, readFile, stat } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import test from "node:test";

const executeFile = promisify(execFile);
const runtimeRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");

test("macOS staging uses the pinned executable and keeps it executable", async () => {
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
  const entrypoint = resolve(
    runtimeRoot,
    "../mgread_plugin_runtime/assets/runtime/macos-arm64/dist/cli.js",
  );
  await Promise.all([access(staged), access(entrypoint)]);
  const [sourceBytes, stagedBytes, stagedStat] = await Promise.all([
    readFile(source),
    readFile(staged),
    stat(staged),
  ]);
  assert.deepEqual(stagedBytes, sourceBytes);
  assert.notEqual(stagedStat.mode & 0o111, 0);
  const { stdout } = await executeFile(staged, ["--version"]);
  assert.equal(stdout.trim(), "v24.16.0");
});
