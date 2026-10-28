/** Actual private host JS contracts: pipe wakeup and async embedded module loading.
 * Uses the pinned desktop Node and local synthetic plugin; no Android device or
 * remote site is involved. Kotlin native callback dispatch is tested separately.
 */
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { cp, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import test from "node:test";
import { createPluginSingleFile, PluginInstaller, PluginManager } from "../dist/index.js";

test("the host wake socket consumes a real pipe event without a timer pump", async () => {
  const source = await readFile(new URL("../../mgread_plugin_runtime/android/src/javet/kotlin/com/mgread/mgread_plugin_runtime/AndroidJavetWakeup.kt", import.meta.url), "utf8");
  const script = source.match(/runtime\.getExecutor\("""([\s\S]*?)"""\.trimIndent\(\)\)/)?.[1];
  assert.ok(script);
  const child = spawn(process.execPath, ["-e", `
    globalThis.__mgreadWakeFailed = () => { throw new Error('wake failed'); };
    globalThis.__mgreadWakeConsumed = () => {
      process.stdout.write('woke');
      __mgreadWakeSocket.removeAllListeners(); __mgreadWakeSocket.destroy();
    };
    ${script.replaceAll("$fd", "0")}
  `], { stdio: ["pipe", "pipe", "pipe"] });
  let output = "", error = "";
  child.stdout.setEncoding("utf8").on("data", chunk => { output += chunk; });
  child.stderr.setEncoding("utf8").on("data", chunk => { error += chunk; });
  const watchdog = setTimeout(() => child.kill(), 5000);
  child.stdin.on("error", () => {});
  child.stdin.write("1");
  const exit = await new Promise(resolve => child.on("exit", resolve));
  clearTimeout(watchdog);
  assert.equal(exit, 0, error);
  assert.equal(output, "woke");
});

test("embedded Core awaits an asynchronous host loader before activating a source", async t => {
  const root = await mkdtemp(join(tmpdir(), "mgread-javet-async-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const project = join(root, "source");
  await cp(new URL("../../../integration_test/fixtures/android-runtime-benchmark/", import.meta.url), project, { recursive: true });
  const artifact = join(root, "source.mgplugin.js");
  await createPluginSingleFile(project, artifact);
  const data = join(root, "data");
  await new PluginInstaller(data).installArtifact(artifact);
  const previous = globalThis.__mgreadLoadPluginModule;
  let loads = 0;
  globalThis.__mgreadLoadPluginModule = async path => {
    loads++;
    await new Promise(resolve => setImmediate(resolve));
    return import(pathToFileURL(path).href);
  };
  t.after(() => {
    if (previous === undefined) delete globalThis.__mgreadLoadPluginModule;
    else globalThis.__mgreadLoadPluginModule = previous;
  });
  const manager = new PluginManager(data, { embedded: true });
  t.after(() => manager.close());
  await manager.initialize();
  const result = await manager.search("org.mgread.android-runtime-benchmark", { query: "plain", cursor: null, pageSize: 1 }, new AbortController().signal, String(Date.now() + 5000));
  assert.equal(result.items[0].title, "benchmark");
  assert.equal(loads, 1);
});
