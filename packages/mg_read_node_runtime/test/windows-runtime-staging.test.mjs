import assert from "node:assert/strict";
import { access, readFile, readdir } from "node:fs/promises";
import { createWindowsRuntimeBundle } from "../tools/bundle-windows-runtime.mjs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import test from "node:test";

const executeFile = promisify(execFile);
const runtimeRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");

test("Windows staging uses the pinned Node executable and Runtime entrypoint", async () => {
  await executeFile(process.execPath, ["tools/stage-flutter-windows-runtime.mjs"], {
    cwd: runtimeRoot,
  });
  const staged = resolve(
    runtimeRoot,
    "../mgread_plugin_runtime/assets/runtime/windows-x64/node/MgReadNode.exe",
  );
  const stagedEntrypoint = resolve(
    runtimeRoot,
    "../mgread_plugin_runtime/assets/runtime/windows-x64/dist/cli.js",
  );
  const stagedNpmPackage = resolve(
    runtimeRoot,
    "../mgread_plugin_runtime/assets/runtime/windows-x64/node/node_modules/npm",
  );
  await access(staged);
  await access(stagedEntrypoint);
  const [source, stagedBytes, sourceDist, stagedDist] = await Promise.all([
    readFile(resolve(runtimeRoot, "tools/node-v26.10.0-win-x64/node.exe")),
    readFile(staged),
    createWindowsRuntimeBundle().then(bundle => Buffer.from(bundle.code)),
    readFile(stagedEntrypoint),
  ]);
  assert.deepEqual(stagedBytes, source);
  assert.deepEqual(stagedDist, sourceDist);
  assert.deepEqual((await readdir(dirname(stagedEntrypoint))).sort(), ["cli.js", "debug-ui"]);
  assert.deepEqual((await readdir(resolve(dirname(stagedEntrypoint), "debug-ui"))).sort(), ["app.css", "app.js", "index.html"]);
  await assert.rejects(access(stagedNpmPackage), { code: "ENOENT" });
  const bun = resolve(runtimeRoot, "../mgread_plugin_runtime/assets/runtime/windows-x64/node/MgReadBun.exe");
  const bunSource = resolve(runtimeRoot, "tools/bun-v1.4.4-windows-x64/bun.exe");
  assert.deepEqual(await readFile(bun), await readFile(bunSource));
  if (process.platform === "win32") {
    const { stdout } = await executeFile(bun, ["--version"]);
    assert.equal(stdout.trim(), "1.4.4");
  }
});
