/**
 * Runtime 双 artifact、v2 传输与 icon loopback 投影测试。
 * 职责：覆盖单文件完整性、安装事务、传输格式和失败隐私 canary。
 * 注意：fixture 仅在临时目录内创建，不执行 npm 或插件构建子进程。
 */
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { access, copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  createPluginSingleFile,
  parsePluginSingleFile,
  PluginInstaller,
  PluginManager,
  PluginSingleFileError,
} from "../dist/index.js";
import {
  isPluginTransferArtifact,
  PluginArtifactTransferManager,
} from "../dist/plugin-artifact-transfer.js";
import { installPluginArtifactInbox } from "../dist/plugin-artifact-inbox.js";

async function temporaryDirectory(t, prefix) {
  const root = await mkdtemp(join(tmpdir(), prefix));
  t.after(() => rm(root, { force: true, recursive: true }));
  return root;
}

async function createSingleFileProject(root) {
  await Promise.all([
    mkdir(join(root, "dist"), { recursive: true }),
    mkdir(join(root, "assets"), { recursive: true }),
  ]);
  const packageJson = {
    name: "@mgread-plugin/single-file-fixture",
    version: "2.1.0",
    type: "module",
    main: "dist/index.mjs",
    engines: { node: ">=24 <25" },
    mgread: {
      schemaVersion: 1,
      id: "org.mgread.single-file-fixture",
      displayName: "Single file fixture",
      pluginApi: 1,
      contentKinds: ["novel"],
      icon: "assets/icon.png",
    },
  };
  const lock = {
    name: packageJson.name,
    version: packageJson.version,
    lockfileVersion: 3,
    requires: true,
    packages: { "": { name: packageJson.name, version: packageJson.version } },
  };
  const code = `/** @type {import("../../types/dispatcher").DispatcherOptions} */
import { createHash } from "node:crypto";
export function activate() { createHash("sha256"); }
export function discover() { return { kind: "document", document: { components: [] } }; }
export function search() { return { items: [], nextCursor: null, totalCount: 0 }; }
export function getDetail() { throw new Error("unused"); }
export function getChapters() { return { items: [] }; }
export function getContent() { throw new Error("unused"); }
`;
  await Promise.all([
    writeFile(join(root, "package.json"), `${JSON.stringify(packageJson, null, 2)}\n`),
    writeFile(join(root, "package-lock.json"), `${JSON.stringify(lock, null, 2)}\n`),
    writeFile(join(root, "dist", "index.mjs"), code),
    writeFile(join(root, "assets", "icon.png"), Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])),
  ]);
  return { code, packageJson };
}

test("single-file artifact is canonical and installs into the shared cold-activation tree", async (t) => {
  const root = await temporaryDirectory(t, "mgread-single-file-");
  const projectRoot = join(root, "project");
  const { code, packageJson } = await createSingleFileProject(projectRoot);
  const artifact = join(root, "fixture.mgplugin.js");
  await createPluginSingleFile(projectRoot, artifact);
  const parsed = await parsePluginSingleFile(artifact);
  assert.equal(parsed.descriptor.mgread.packageMode, "single-file");
  assert.equal(parsed.descriptor.mgread.id, packageJson.mgread.id);
  assert.equal(parsed.envelope.codeBytes, Buffer.byteLength(code));
  assert.equal(parsed.icon.bytes.byteLength, 8);

  const dataRoot = join(root, "runtime-data");
  const installProgress = [];
  const installed = await new PluginInstaller(dataRoot, {
    onProgress: (progress) => installProgress.push(progress.detail),
  }).installArtifact(artifact);
  assert.equal(installed.descriptor.packageMode, "single-file");
  assert.equal(installed.descriptor.entry, "dist/index.mjs");
  const retained = join(dataRoot, "plugin-archives", packageJson.mgread.id, "2.1.0.mgplugin.js");
  assert.deepEqual(await readFile(retained), await readFile(artifact));
  const installedLock = JSON.parse(await readFile(join(dataRoot, "plugins", packageJson.mgread.id, "versions", "2.1.0", "package-lock.json"), "utf8"));
  assert.deepEqual(installedLock.packages, { "": { name: packageJson.name, version: packageJson.version } });
  await assert.rejects(access(join(dataRoot, "plugins", packageJson.mgread.id, "versions", "2.1.0", "node_modules")));
  assert.ok(installProgress.includes("已验证单文件数据源插件，npm 依赖已打包，无需安装"));
  assert.ok(installProgress.includes("单文件数据源插件安装完成，无需安装 npm 依赖"));

  const inboxRoot = join(root, "sync-inbox");
  await mkdir(inboxRoot, { recursive: true });
  await copyFile(artifact, join(inboxRoot, "synced.mgplugin.js"));
  const syncProgress = [];
  await installPluginArtifactInbox(dataRoot, inboxRoot, (progress) => syncProgress.push(progress.detail));
  assert.ok(syncProgress.includes("单文件数据源插件版本已存在，无需安装 npm 依赖"));
  await assert.rejects(access(join(inboxRoot, "synced.mgplugin.js")));

  const manager = new PluginManager(dataRoot);
  t.after(() => manager.close());
  await manager.initialize();
  const snapshot = (await manager.listInstalled())[0];
  assert.equal(typeof snapshot.iconUrl, "string");
  assert.match(snapshot.iconUrl, /^http:\/\/127\.0\.0\.1\/v1\/plugin-icon\//);
  const token = new URL(snapshot.iconUrl).pathname.split("/").at(-1);
  const icon = await manager.consumePluginIconResource(token);
  assert.equal(icon.mediaType, "image/png");
  assert.equal(icon.body.byteLength, 8);

  const secretCanary = "Authorization: Bearer mgread-secret-canary novel-content-canary";
  const tampered = Buffer.concat([await readFile(artifact), Buffer.from(secretCanary)]);
  const tamperedPath = join(root, "tampered.mgplugin.js");
  await writeFile(tamperedPath, tampered);
  await assert.rejects(parsePluginSingleFile(tamperedPath), PluginSingleFileError);

  const events = [];
  const failingInstaller = new PluginInstaller(dataRoot, { events: (event) => events.push(event) });
  let failure;
  try {
    await failingInstaller.installArtifact(tamperedPath);
    assert.fail("tampered artifact must fail installation");
  } catch (error) {
    failure = error;
  }
  assert.deepEqual(events.map(({ code, outcome }) => ({ code, outcome })), [
    { code: "plugin_install_started", outcome: "started" },
    { code: "plugin_install_failed", outcome: "error" },
  ]);
  assert.doesNotMatch(JSON.stringify({ events, message: failure?.message }), /mgread-secret-canary|novel-content-canary/u);
  assert.deepEqual(await readFile(retained), await readFile(artifact));

  await manager.scheduleUninstall(packageJson.mgread.id);
  const restartedManager = new PluginManager(dataRoot);
  t.after(() => restartedManager.close());
  await restartedManager.initialize();
  assert.deepEqual(await restartedManager.listInstalled(), []);
  await assert.rejects(access(retained));
  await assert.rejects(access(join(dataRoot, "plugin-data", packageJson.mgread.id)));
  await assert.rejects(access(join(dataRoot, "plugin-cache", packageJson.mgread.id)));

  await writeFile(join(projectRoot, "dist", "index.mjs"), 'const moduleName = "external-package"; await import(moduleName);\n');
  const directStartArtifact = join(root, "direct-start.mgplugin.js");
  await createPluginSingleFile(projectRoot, directStartArtifact);
  assert.equal((await parsePluginSingleFile(directStartArtifact)).code.toString("utf8"), 'const moduleName = "external-package"; await import(moduleName);\n');
});

test("artifact transfer v2 lists both retained formats and rejects v1-shaped items", async (t) => {
  const root = await temporaryDirectory(t, "mgread-artifact-transfer-");
  const archive = Buffer.from("legacy archive bytes");
  const single = Buffer.from("single file bytes");
  const archiveRoot = join(root, "plugin-archives", "org.example.source");
  const singleRoot = join(root, "plugin-archives", "org.example.single");
  await Promise.all([mkdir(archiveRoot, { recursive: true }), mkdir(singleRoot, { recursive: true })]);
  await Promise.all([
    writeFile(join(archiveRoot, "1.2.0.mgplugin"), archive),
    writeFile(join(singleRoot, "1.0.0.mgplugin.js"), single),
  ]);
  const manager = new PluginArtifactTransferManager(root);
  t.after(() => manager.dispose());
  const listed = await manager.listExportable([
    { id: "org.example.source", activeVersion: "1.2.0", pendingVersion: null },
    { id: "org.example.single", activeVersion: "1.0.0", pendingVersion: null },
  ]);
  assert.deepEqual(listed, [
    { bytes: single.length, format: "singleFile", id: "org.example.single", sha256: createHash("sha256").update(single).digest("hex"), version: "1.0.0" },
    { bytes: archive.length, format: "archive", id: "org.example.source", sha256: createHash("sha256").update(archive).digest("hex"), version: "1.2.0" },
  ]);
  assert.equal(isPluginTransferArtifact({ bytes: 1, id: "org.example.old", sha256: "0".repeat(64), version: "1.0.0" }), false);
});
