import assert from "node:assert/strict";
import { once } from "node:events";
import { spawn } from "node:child_process";
import { access, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const stagedRuntimeRoot = resolve(
  packageRoot,
  "..",
  "mgread_plugin_runtime",
  "assets",
  "runtime",
  "windows-x64",
);
const stagedNode = join(stagedRuntimeRoot, "node", "MgReadNode.exe");
const stagedCli = join(stagedRuntimeRoot, "dist", "cli.js");

test("staged Windows Runtime assets match the freshly compiled Runtime", { skip: process.platform !== "win32" }, async () => {
  assert.deepEqual(
    await readFile(stagedCli),
    await readFile(join(packageRoot, "dist", "cli.js")),
  );
  await access(stagedNode);
});

test(
  "staged Windows Runtime becomes ready without a development source root",
  { skip: process.platform !== "win32" },
  async (t) => {
    const dataRoot = await mkdtemp(join(tmpdir(), "mgread-staged-runtime-basic-"));
    const child = spawn(stagedNode, [
      stagedCli,
      `--data-root=${dataRoot}`,
      "--debug-http-enabled=1",
    ], { stdio: ["ignore", "pipe", "pipe"] });
    t.after(async () => {
      await stopChild(child);
      await rm(dataRoot, { force: true, recursive: true });
    });

    const ready = await waitForRecord(child, "stdout", (record) => record.type === "ready");
    assert.equal(ready.type, "ready");
    assert.equal(ready.nodeVersion, "26.10.0");
  },
);

test(
  "staged Windows Runtime becomes ready with a development root and no npm CLI",
  { skip: process.platform !== "win32" },
  async (t) => {
    const dataRoot = await mkdtemp(join(tmpdir(), "mgread-staged-runtime-data-"));
    const developmentRoot = await mkdtemp(join(tmpdir(), "mgread-staged-runtime-dev-"));
    const child = spawn(stagedNode, [
      "--preserve-symlinks",
      stagedCli,
      `--data-root=${dataRoot}`,
      "--debug-http-enabled=1",
      `--development-plugin-root=${developmentRoot}`,
    ], { stdio: ["ignore", "pipe", "pipe"] });
    t.after(async () => {
      await stopChild(child);
      await Promise.all([
        rm(dataRoot, { force: true, recursive: true }),
        rm(developmentRoot, { force: true, recursive: true }),
      ]);
    });

    const ready = await waitForRecord(child, "stdout", (record) => record.type === "ready");
    assert.equal(ready.type, "ready");
    assert.equal(ready.nodeVersion, "26.10.0");
    assert.equal(ready.protocolVersion, "1.2");
  },
);

test(
  "invalid staged launch options return a safe stable diagnostic",
  { skip: process.platform !== "win32" },
  async (t) => {
    const dataRoot = await mkdtemp(join(tmpdir(), "mgread-staged-runtime-invalid-"));
    const privateCanary = "C:\\private\\RUNTIME-SECRET-CANARY";
    const child = spawn(stagedNode, [
      stagedCli,
      `--data-root=${dataRoot}`,
      `--invalid-option=${privateCanary}`,
    ], { stdio: ["ignore", "pipe", "pipe"] });
    t.after(async () => {
      await stopChild(child);
      await rm(dataRoot, { force: true, recursive: true });
    });

    const childExit = once(child, "exit");
    const fatal = await waitForRecord(child, "stderr", (record) => record.type === "fatal");
    const [exitCode] = await childExit;
    assert.equal(exitCode, 1);
    assert.equal(fatal.code, "runtime_invalid_launch_options");
    assert.match(fatal.message, /启动参数无效或与当前应用版本不兼容/);
    assert.doesNotMatch(JSON.stringify(fatal), /RUNTIME-SECRET-CANARY|C:\\\\private|stack/i);
  },
);

function waitForRecord(child, streamName, matches, timeoutMs = 10_000) {
  const stream = streamName === "stdout" ? child.stdout : child.stderr;
  let buffered = "";
  let recentRecords = [];
  return new Promise((resolveRecord, reject) => {
    const timer = setTimeout(() => {
      cleanup();
      reject(new Error(`Timed out waiting for a staged Runtime ${streamName} record.`));
    }, timeoutMs);
    const onData = (chunk) => {
      buffered += String(chunk);
      const lines = buffered.split(/\r?\n/);
      buffered = lines.pop() ?? "";
      for (const line of lines) {
        try {
          const record = JSON.parse(line);
          recentRecords.push(record);
          recentRecords = recentRecords.slice(-6);
          if (matches(record)) {
            cleanup();
            resolveRecord(record);
            return;
          }
        } catch {
          // Ignore non-record lines; only structured Runtime records are used.
        }
      }
    };
    const onExit = (code) => {
      cleanup();
      reject(new Error(`Staged Runtime exited before the expected record (code ${code}); records=${JSON.stringify(recentRecords)}`));
    };
    const cleanup = () => {
      clearTimeout(timer);
      stream.off("data", onData);
      child.off("exit", onExit);
    };
    stream.on("data", onData);
    child.once("exit", onExit);
  });
}

async function stopChild(child) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  const exited = once(child, "exit");
  child.kill();
  const result = await Promise.race([
    exited.then(() => true),
    new Promise((resolveResult) => setTimeout(() => resolveResult(false), 2_000)),
  ]);
  if (!result && child.exitCode === null && child.signalCode === null) {
    child.kill("SIGKILL");
    await once(child, "exit");
  }
}
