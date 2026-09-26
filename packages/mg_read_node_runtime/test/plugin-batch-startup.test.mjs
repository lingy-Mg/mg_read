/** Batch inbox limits, bounded cold activation, warm metadata and transfer verification. */
import assert from "node:assert/strict";
import { copyFile, mkdir, mkdtemp, open, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { PluginManager } from "../dist/plugin-manager.js";
import { installPluginArtifactInbox } from "../dist/plugin-artifact-inbox.js";
import { PluginArtifactTransferManager } from "../dist/plugin-artifact-transfer.js";
import { crc32 } from "../dist/lan-sync-checksum.js";
import { createTransferBatch } from "./fixtures/transfer-batch.mjs";

test("40 sources install in one inbox pass and cold activation is bounded and concurrent", async (t) => {
  const root = await mkdtemp(join(tmpdir(), "mgread-batch-startup-"));
  t.after(() => rm(root, {recursive: true, force: true}));
  const artifacts = await createTransferBatch(root, 40, "await new Promise(resolve => setTimeout(resolve, 30));");
  const data = join(root, "data");
  const inbox = join(data, "import-inbox");
  await mkdir(inbox, {recursive: true});
  for (const {path, artifact} of artifacts) await copyFile(path, join(inbox, `${artifact.id}.mgplugin.js`));
  const start = performance.now();
  const installed = await installPluginArtifactInbox(data, inbox, () => {});
  assert.equal(installed.installedCount, 40);
  assert.deepEqual(await readdir(inbox), []);
  let active = 0;
  let peak = 0;
  const manager = new PluginManager(data, {events(event) {
    if (event.code === "plugin_load_started") peak = Math.max(peak, ++active);
    if (event.code === "plugin_load_completed" || event.code === "plugin_load_failed") active--;
  }});
  t.after(() => manager.close());
  await manager.initialize();
  const snapshots = await manager.listInstalled();
  assert.equal(snapshots.length, 40);
  assert.ok(snapshots.every(item => item.status === "active" && item.pendingVersion === null));
  assert.ok(peak > 1 && peak <= 8, `load concurrency was ${peak}`);
  assert.equal(active, 0);
  t.diagnostic(`40-source install + activation: ${Math.round(performance.now() - start)} ms; peak loads=${peak}`);
  await manager.close();
  const events = [];
  const restarted = new PluginManager(data, {events: event => events.push(event)});
  t.after(() => restarted.close());
  const restartStart = performance.now();
  await restarted.initialize();
  assert.equal((await restarted.listInstalled()).length, 40);
  assert.equal(events.filter(event => event.code === "plugin_load_started").length, 0);
  assert.equal(events.find(event => event.startupPhase === "installed_snapshot").catalogState, "hit");
  t.diagnostic(`40-source metadata restart: ${Math.round(performance.now() - restartStart)} ms; modules loaded=0`);
});

test("inbox enforces 512 MiB before installing any file", async (t) => {
  const root = await mkdtemp(join(tmpdir(), "mgread-inbox-budget-"));
  t.after(() => rm(root, {recursive: true, force: true}));
  const inbox = join(root, "inbox");
  await mkdir(inbox);
  for (let index = 0; index < 17; index++) {
    const file = await open(join(inbox, `${index}.mgplugin.js`), "w");
    await file.truncate(32 * 1024 * 1024);
    await file.close();
  }
  await assert.rejects(installPluginArtifactInbox(join(root, "data"), inbox, () => {}), /inbox is over budget/);
  assert.equal((await readdir(inbox)).length, 17);
});

test("equal-size inbox verification handles reordered files and duplicate checksums", async (t) => {
  const root = await mkdtemp(join(tmpdir(), "mgread-inbox-hashes-"));
  t.after(() => rm(root, {recursive: true, force: true}));
  const inbox = join(root, "import-inbox");
  await mkdir(inbox);
  const incoming = [];
  for (let index = 0; index < 40; index++) {
    const bytes = Buffer.from(String(index % 20).padStart(8, "0"));
    await writeFile(join(inbox, `${String(index).padStart(3, "0")}.mgplugin.js`), bytes);
    incoming.unshift({id: `org.test.${index}`, bytes: bytes.length, checksum: crc32(bytes),
      format: "singleFile", version: "1.0.0", provenance: "installed",
      developmentFingerprint: null, developmentRevision: null});
  }
  const transfer = new PluginArtifactTransferManager(root);
  t.after(() => transfer.dispose());
  await transfer.verifyInbox(incoming);
  await rm(join(inbox, "000.mgplugin.js"));
  await assert.rejects(transfer.verifyInbox(incoming), error => error.code === "plugin_transfer_checksum_mismatch");
});
