/** Runtime artifact transfer v2 的索引、规划和格式拒绝测试。 */
import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createHash } from "node:crypto";
import test from "node:test";

import {
  MAX_PLUGIN_TRANSFER_BATCH,
  MAX_PLUGIN_TRANSFER_BYTES,
  PluginTransferManager,
} from "../dist/plugin-transfer.js";

test("plugin transfer v2 lists retained artifacts and plans SemVer", async (t) => {
  const root = await mkdtemp(join(tmpdir(), "mgread-transfer-test-"));
  t.after(() => rm(root, { force: true, recursive: true }));
  const archive = Buffer.from("bounded plugin archive");
  const archivePath = join(root, "plugin-archives", "org.example.source", "1.2.0.mgplugin");
  await mkdir(join(root, "plugin-archives", "org.example.source"), { recursive: true });
  await writeFile(archivePath, archive);
  const sha256 = createHash("sha256").update(archive).digest("hex");
  const manager = new PluginTransferManager(root);
  const listed = await manager.listExportable([{ id: "org.example.source", activeVersion: "1.2.0", pendingVersion: null }]);
  assert.deepEqual(listed, [{
    bytes: archive.length,
    developmentFingerprint: null,
    developmentRevision: null,
    format: "archive",
    id: "org.example.source",
    provenance: "installed",
    sha256,
    version: "1.2.0",
  }]);
  const installed = [{ id: "org.example.source", activeVersion: "1.0.0", pendingVersion: null }];
  const plan = manager.plan([
    { bytes: archive.length, developmentFingerprint: null, developmentRevision: null, format: "archive", id: "org.example.source", provenance: "installed", sha256, version: "1.2.0" },
    { bytes: archive.length, developmentFingerprint: null, developmentRevision: null, format: "singleFile", id: "org.new.source", provenance: "installed", sha256, version: "1.0.0" },
  ], installed);
  assert.deepEqual(plan.map((item) => item.action), ["upgrade", "missing"]);
  const localDevelopmentPlan = manager.plan(
    [{
      bytes: archive.length,
      developmentFingerprint: null,
      developmentRevision: null,
      format: "archive",
      id: "org.example.source",
      provenance: "installed",
      sha256,
      version: "9.0.0",
    }],
    installed,
    [{ fingerprint: "a".repeat(64), id: "org.example.source", syncRevision: 1 }],
  );
  assert.equal(localDevelopmentPlan[0].action, "developmentConflict");
  const developmentReplicaPlan = manager.plan(
    [{
      bytes: archive.length,
      developmentFingerprint: "b".repeat(64),
      developmentRevision: 2,
      format: "archive",
      id: "org.example.source",
      provenance: "developmentReplica",
      sha256,
      version: `1.0.1-devsync.2.${"b".repeat(64)}`,
    }],
    installed,
    [{ fingerprint: "a".repeat(64), id: "org.example.source", syncRevision: 1 }],
  );
  assert.equal(developmentReplicaPlan[0].action, "developmentConflict");
  assert.ok(MAX_PLUGIN_TRANSFER_BYTES >= archive.length);
  assert.equal(MAX_PLUGIN_TRANSFER_BATCH, 32);
  assert.throws(
    () => manager.plan([{ bytes: archive.length, id: "org.old.source", sha256, version: "1.0.0" }], installed),
    (error) => error?.code === "invalid_request",
  );
});
