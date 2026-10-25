/** Old installed metadata must survive catalog rebuilds and lazy first use. */
import assert from "node:assert/strict";
import { copyFile, cp, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { PluginManager } from "../dist/plugin-manager.js";
import { readPluginProject } from "../dist/plugin-package.js";
import { createPluginArchive } from "../dist/plugin-archive.js";
import { createPluginSingleFile, parsePluginSingleFile } from "../dist/plugin-single-file.js";
import { verifyPluginArtifactIdentity } from "../dist/plugin-import-batch.js";
import { installPluginArtifactInbox } from "../dist/plugin-artifact-inbox.js";

const pluginId = "org.mgread.runtime.fixture";
const fixture = new URL("./fixtures/standard-plugin/", import.meta.url);

async function installedFixture(t, pointer = "current") {
  const root = await mkdtemp(join(tmpdir(), "mgread-installed-legacy-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const pluginRoot = join(root, "plugins", pluginId);
  const versionRoot = join(pluginRoot, "versions", "1.0.0");
  await cp(fixture, versionRoot, { recursive: true });
  const packagePath = join(versionRoot, "package.json");
  const metadata = JSON.parse(await readFile(packagePath, "utf8"));
  delete metadata.mgread.sourceUrl;
  await writeFile(packagePath, JSON.stringify(metadata));
  await writeFile(join(pluginRoot, pointer), "1.0.0\n");
  return { root, pluginRoot, versionRoot, packagePath, metadata };
}

function search(manager) {
  return manager.search(pluginId, { query: "legacy", cursor: null, pageSize: 5 },
    new AbortController().signal, String(Date.now() + 10_000));
}

for (const pointer of ["current", "pending"]) {
  test(`installed legacy ${pointer} survives repair, activation and trusted-index restart`, async (t) => {
    const { root, packagePath } = await installedFixture(t, pointer);
    const original = await readFile(packagePath);
    const first = new PluginManager(root, { embedded: true });
    t.after(() => first.close());
    await first.initialize();
    assert.equal((await first.listInstalled())[0].status, "active");
    assert.equal((await first.listInstalled())[0].sourceUrl, null);
    assert.equal((await search(first)).items[0].title, "标准插件：legacy");
    await first.close();

    const events = [];
    const restarted = new PluginManager(root, { embedded: true, events: event => events.push(event) });
    t.after(() => restarted.close());
    await restarted.initialize();
    assert.equal(events.find(event => event.startupPhase === "installed_snapshot").catalogState, "hit");
    assert.equal(events.filter(event => event.code === "plugin_load_started").length, 0);
    assert.equal((await search(restarted)).items[0].title, "标准插件：legacy");
    assert.deepEqual(await readFile(packagePath), original, "immutable installed metadata stays unchanged");
  });
}

test("legacy compatibility only permits an absent sourceUrl and keeps other checks", async (t) => {
  const { versionRoot, packagePath, metadata } = await installedFixture(t);
  assert.equal((await readPluginProject(versionRoot)).descriptor.sourceUrl, undefined);
  for (const value of [null, "", "javascript:alert(1)", "http://localhost/"]) {
    metadata.mgread.sourceUrl = value;
    await writeFile(packagePath, JSON.stringify(metadata));
    await assert.rejects(readPluginProject(versionRoot), { code: "plugin_package_invalid" });
  }
  delete metadata.mgread.sourceUrl;
  metadata.mgread.pluginApi = 999;
  await writeFile(packagePath, JSON.stringify(metadata));
  await assert.rejects(readPluginProject(versionRoot), { code: "plugin_package_invalid" });
});

test("quarantined legacy source reports load failure and can be explicitly re-enabled", async (t) => {
  const { root, pluginRoot } = await installedFixture(t);
  await writeFile(join(pluginRoot, "quarantined"), "1.0.0\n");
  const manager = new PluginManager(root);
  t.after(() => manager.close());
  await manager.initialize();
  assert.equal((await manager.listInstalled())[0].status, "quarantined");
  await assert.rejects(search(manager), error => error.code === "plugin_load_failed" && error.detail.includes("quarantined"));
  await manager.setEnabled(pluginId, true);
  assert.equal((await search(manager)).items[0].title, "标准插件：legacy");
  assert.equal((await manager.listInstalled())[0].status, "active");
  await manager.setEnabled(pluginId, false);
  await assert.rejects(search(manager), { code: "plugin_disabled" });
});

for (const format of ["archive", "singleFile"]) {
  test(`legacy ${format} passes LAN identity verification, inbox install, first use and re-export`, async (t) => {
    const { root, versionRoot, metadata, packagePath } = await installedFixture(t);
    metadata.mgread.packageMode = format === "archive" ? "archive" : "single-file";
    await writeFile(packagePath, JSON.stringify(metadata));
    const artifact = join(root, format === "archive" ? "old.mgplugin" : "old.mgplugin.js");
    if (format === "archive") await createPluginArchive(versionRoot, artifact);
    else {
      await createPluginSingleFile(versionRoot, artifact);
      assert.equal((await parsePluginSingleFile(artifact)).descriptor.mgread.sourceUrl, undefined);
    }
    await verifyPluginArtifactIdentity(artifact, { id: pluginId, version: "1.0.0", format });
    const receivingRoot = join(root, "receiver");
    const inbox = join(receivingRoot, "import-inbox");
    await mkdir(inbox, { recursive: true });
    await copyFile(artifact, join(inbox, format === "archive" ? "old.mgplugin" : "old.mgplugin.js"));
    assert.equal((await installPluginArtifactInbox(receivingRoot, inbox, () => {})).installedCount, 1);
    const manager = new PluginManager(receivingRoot);
    t.after(() => manager.close());
    await manager.initialize();
    assert.equal((await search(manager)).items[0].title, "标准插件：legacy");
    const exported = await manager.listExportableArtifacts();
    assert.equal(exported.length, 1);
    assert.equal(exported[0].format, format);
    assert.equal((await manager.listInstalled())[0].sourceUrl, null);
  });
}
