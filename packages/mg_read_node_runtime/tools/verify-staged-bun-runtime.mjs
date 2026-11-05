/** Executes the release-staged Bun helper from an unrelated working directory.
 * Verifies bundled dependencies, installed source dispatch and graceful exit;
 * all writable data and fixture requests stay inside a private test directory.
 */
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, resolve } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { PluginInstaller } from "../dist/index.js";
import { bunVersion } from "./stage-bun-runtime.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const platform = process.platform === "win32" ? "windows-x64" : "macos-arm64";
// CI also points these at the final Flutter bundle, after copy/sign operations.
const bundle = process.env.MGREAD_BUN_BUNDLE_ROOT ?? resolve(root, `../mgread_plugin_runtime/assets/runtime/${platform}`);
const executable = process.env.MGREAD_BUN_EXECUTABLE ??
  resolve(bundle, "node", process.platform === "win32" ? "MgReadBun.exe" : "MgReadBun");

test("staged Bun serves an installed source, reports its identity and shuts down", { timeout: 20000 }, async t => {
  const data = await mkdtemp(resolve(tmpdir(), "mgread-staged-bun-"));
  await new PluginInstaller(data).installProject(resolve(root, "test/fixtures/standard-plugin"));
  // A caller's dotenv must never affect the runtime launch or trigger install.
  await writeFile(resolve(data, ".env"), "NODE_OPTIONS=--invalid-test-option\n");
  const child = spawn(executable, [
    "--no-env-file", "--no-install", resolve(bundle, "dist/cli.js"), `--data-root=${data}`, '--debug-http-enabled=1',
  ], { cwd: data, stdio: ["ignore", "pipe", "pipe"], windowsHide: true });
  const exited = once(child, "exit");
  let diagnostics = "";
  child.stderr.on("data", bytes => { diagnostics = (diagnostics + bytes).slice(-4000); });
  const lines = createInterface({ input: child.stdout });
  let socket;
  t.after(async () => {
    socket?.close();
    lines.close();
    if (child.exitCode === null && child.signalCode === null) child.kill();
    await exited;
    await rm(data, { recursive: true, force: true });
  });
  const ready = await Promise.race([
    new Promise(resolveReady => lines.on("line", line => {
      const record = JSON.parse(line);
      if (record.type === "ready") resolveReady(record);
    })),
    exited.then(() => { throw new Error(`Bun exited before ready: ${diagnostics}`); }),
  ]);
  assert.equal(ready.bunVersion, bunVersion);
  const health = await (await fetch(`http://${ready.host}:${ready.port}/health/ready`)).json();
  assert.equal(health.bunVersion, bunVersion);
  socket = new WebSocket(`ws://${ready.host}:${ready.port}/v1/rpc`);
  await once(socket, "open");
  let serial = 0;
  const invoke = async (method, params = {}) => {
    const id = `c:${++serial}`;
    const response = once(socket, "message");
    socket.send(JSON.stringify({ v: "1.2", type: "request", bootId: ready.bootId,
      id, traceId: id, idempotencyKey: `staged-${id}`, deadlineUnixMs: String(Date.now() + 5000), method, params }));
    const message = JSON.parse((await response)[0].data);
    assert.equal(message.type, "response", JSON.stringify(message));
    return message.result;
  };
  const status = await invoke("runtime.status.v1");
  assert.equal(status.runtimeKind, "desktop-bun");
  assert.equal(status.bunVersion, bunVersion);
  const result = await invoke("source.search.v1", { pluginId: "org.mgread.runtime.fixture", query: "交付验收", cursor: null, pageSize: 20 });
  assert.equal(result.items.length, 1);
  const debug = await invoke("runtime.debugHttp.setEnabled.v1", { enabled: true });
  const inspector = debug.endpoints.find(value => value.startsWith('http://127.0.0.1:'));
  assert.ok(inspector);
  for (const [route, marker] of [['', '<mg-debug-app'], ['/__debug/app.css', '.workspace-panel'], ['/__debug/app.js', 'customElements.define']]) {
    const response = await fetch(new URL(route, inspector));
    assert.equal(response.status, 200);
    assert.ok((await response.text()).includes(marker), `Bundled inspector asset: ${route}`);
  }
  await invoke("runtime.debugHttp.setEnabled.v1", { enabled: false });
  await invoke("runtime.shutdown");
  const [code] = await exited;
  assert.equal(code, 0, diagnostics);
});
