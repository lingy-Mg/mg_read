import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import test from "node:test";

const executeFile = promisify(execFile);
const runtimeRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");

test("Windows staging uses the MgRead-prefixed pinned Node executable", async () => {
  await executeFile(process.execPath, ["tools/stage-flutter-windows-runtime.mjs"], {
    cwd: runtimeRoot,
  });
  const staged = resolve(
    runtimeRoot,
    "packages/mgread_plugin_runtime/assets/runtime/windows-x64/node/MgReadNode.exe",
  );
  await access(staged);
  const [source, stagedBytes] = await Promise.all([
    readFile(resolve(runtimeRoot, "tools/node-v24.16.0-win-x64/node.exe")),
    readFile(staged),
  ]);
  assert.deepEqual(stagedBytes, source);
});
