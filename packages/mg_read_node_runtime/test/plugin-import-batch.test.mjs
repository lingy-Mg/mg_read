/** Shared import contract: staged visibility, identity, path bounds and replacement exports. */
import assert from "node:assert/strict";
import { chmod, copyFile, mkdir, mkdtemp, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import test from "node:test";
import { createTransferBatch } from "./fixtures/transfer-batch.mjs";
import { importBatchDirectory, verifyPluginImportBatch } from "../dist/plugin-import-batch.js";
import { installPluginArtifactInbox } from "../dist/plugin-artifact-inbox.js";
import { PluginArtifactTransferManager } from "../dist/plugin-artifact-transfer.js";

async function fixture(t, count = 2) {
  const root = await mkdtemp(join(tmpdir(), "mgread-import-contract-"));
  t.after(() => rm(root, {recursive: true, force: true}));
  const records = await createTransferBatch(join(root, "fixture"), count);
  const data = join(root, "data");
  const inbox = join(data, "import-inbox");
  const id = "a".repeat(32);
  const staging = importBatchDirectory(inbox, id, true);
  await mkdir(staging, {recursive: true});
  const artifacts = records.map((record, index) => ({...record.artifact, file: `${index}.mgplugin.js`}));
  for (let index = 0; index < records.length; index++) await copyFile(records[index].path, join(staging, `${index}.mgplugin.js.part`));
  await writeFile(join(staging, "manifest.json"), JSON.stringify({schemaVersion: 1, artifacts}));
  return {root, data, inbox, id, staging, records, artifacts};
}

async function publish(f) {
  for (let index = 0; index < f.records.length; index++) await rename(join(f.staging, `${index}.mgplugin.js.part`), join(f.staging, `${index}.mgplugin.js`));
  await rename(f.staging, importBatchDirectory(f.inbox, f.id, false));
}

test("unpublished directories are invisible, a published batch recovers on cold startup", async (t) => {
  const f = await fixture(t, 40);
  assert.equal((await installPluginArtifactInbox(f.data, f.inbox, () => {})).installedCount, 0);
  const transfer = new PluginArtifactTransferManager(f.data);
  await transfer.verifyInbox(f.records.map((record) => record.artifact), f.id);
  await publish(f);
  const result = await installPluginArtifactInbox(f.data, f.inbox, () => {});
  assert.deepEqual(result, {discoveredCount: 40, installedCount: 40});
  assert.deepEqual(await readdir(f.inbox), []);
});

test("wrong embedded identity rejects the entire batch before installing earlier entries", async (t) => {
  const f = await fixture(t);
  f.artifacts[1].id = "org.test.advertised";
  f.artifacts[1].version = "9.0.0";
  await writeFile(join(f.staging, "manifest.json"), JSON.stringify({schemaVersion: 1, artifacts: f.artifacts}));
  await assert.rejects(verifyPluginImportBatch(f.inbox, f.id, true), {code: "plugin_transfer_checksum_mismatch"});
  await publish(f);
  await assert.rejects(installPluginArtifactInbox(f.data, f.inbox, () => {}), {code: "plugin_transfer_checksum_mismatch"});
  assert.deepEqual(await readdir(f.inbox), []);
  await assert.rejects(readdir(join(f.data, "plugins")), {code: "ENOENT"});
});

test("corrupt last file and path traversal cannot publish or install an earlier entry", async (t) => {
  const f = await fixture(t);
  await chmod(join(f.staging, "1.mgplugin.js.part"), 0o644);
  await writeFile(join(f.staging, "1.mgplugin.js.part"), Buffer.alloc(f.artifacts[1].bytes));
  await assert.rejects(verifyPluginImportBatch(f.inbox, f.id, true), {code: "plugin_transfer_checksum_mismatch"});
  assert.throws(() => importBatchDirectory(f.inbox, "../escape", true), {code: "invalid_request"});
  f.artifacts[0].file = "../escape.mgplugin.js";
  await writeFile(join(f.staging, "manifest.json"), JSON.stringify({schemaVersion: 1, artifacts: f.artifacts}));
  await assert.rejects(verifyPluginImportBatch(f.inbox, f.id, true), {code: "invalid_request"});
});

test("verification binds the manifest to the caller's approved descriptors", async (t) => {
  const f = await fixture(t);
  const incoming = f.records.map((record) => record.artifact);
  incoming[0] = {...incoming[0], id: "org.test.other"};
  await assert.rejects(verifyPluginImportBatch(f.inbox, f.id, true, incoming), {code: "plugin_transfer_checksum_mismatch"});
});

test("forced same-version replacement retains and exports the replacement bytes", async (t) => {
  const f = await fixture(t, 1);
  await publish(f);
  await installPluginArtifactInbox(f.data, f.inbox, () => {});
  const [replacement] = await createTransferBatch(join(f.root, "replacement"), 1, "/* replacement */");
  await copyFile(replacement.path, join(f.inbox, "replacement.mgplugin.js"));
  await installPluginArtifactInbox(f.data, f.inbox, () => {});
  const retained = await readFile(join(f.data, "plugin-archives", replacement.artifact.id, "1.0.0.mgplugin.js"));
  assert.deepEqual(retained, await readFile(replacement.path));
  const transfer = new PluginArtifactTransferManager(f.data);
  const offered = await transfer.listExportable([{id: replacement.artifact.id, activeVersion: "1.0.0", pendingVersion: null}]);
  assert.equal(offered[0].checksum, replacement.artifact.checksum);
});
