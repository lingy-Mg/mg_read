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
  const stagedNpmCli = resolve(
    runtimeRoot,
    "packages/mgread_plugin_runtime/assets/runtime/windows-x64/node/node_modules/npm/bin/npm-cli.js",
  );
  await access(staged);
  await access(stagedNpmCli);
  const [source, stagedBytes, sourceNpmPackage, stagedNpmPackage] = await Promise.all([
    readFile(resolve(runtimeRoot, "tools/node-v24.16.0-win-x64/node.exe")),
    readFile(staged),
    readFile(resolve(runtimeRoot, "tools/node-v24.16.0-win-x64/node_modules/npm/package.json")),
    readFile(resolve(runtimeRoot, "packages/mgread_plugin_runtime/assets/runtime/windows-x64/node/node_modules/npm/package.json")),
  ]);
  assert.deepEqual(stagedBytes, source);
  assert.deepEqual(stagedNpmPackage, sourceNpmPackage);
});
