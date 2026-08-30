import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  cp,
  mkdtemp,
  mkdir,
  readFile,
  rm,
  stat,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { gzipSync } from "node:zlib";
import test from "node:test";

import {
  createPluginArchive,
  DependencyStore,
  extractPluginArchive,
  PluginArchiveError,
  PluginInstaller,
  PluginManager,
  PluginPackageError,
  readPluginProject,
} from "../dist/index.js";
import {
  PluginContentValidationError,
  parseChaptersParams,
  validateChaptersResult,
  validateContentResult,
  validateDetailResult,
  validateDiscoverResult,
  validateSearchResult,
} from "../dist/plugin-content.js";

import {
  createDelayedPlugin,
  createDevelopmentPlugin,
  createRegistryPlugin,
  fileExists,
  makeNpmTarball,
  replaceAllAscii,
  writeTarOctal,
  writeTarString,
} from "./plugin-system-fixtures.mjs";

const fixtureRoot = fileURLToPath(
  new URL("./fixtures/standard-plugin/", import.meta.url),
);

async function temporaryDirectory(t, prefix) {
  const root = await mkdtemp(join(tmpdir(), prefix));
  t.after(() => rm(root, { force: true, recursive: true }));
  return root;
}
test("standard project uses package.json metadata and npm lockfile only", async () => {
  const project = await readPluginProject(fixtureRoot);
  assert.equal(project.descriptor.id, "org.mgread.runtime.fixture");
  assert.equal(project.descriptor.packageMode, "archive");
  assert.equal(project.descriptor.entry, "dist/index.mjs");
  assert.deepEqual(project.descriptor.contentKinds, ["novel"]);
  assert.deepEqual(project.dependencies, [
    {
      installPath: "node_modules/local-helper",
      kind: "local",
      optional: false,
      resolved: "packages/local-helper",
      sourcePath: "packages/local-helper",
      version: "1.0.0",
    },
  ]);
});

test("legacy manifest-only projects are rejected without a compatibility path", async (t) => {
  const root = await temporaryDirectory(t, "mgread-legacy-plugin-");
  await writeFile(
    join(root, "manifest.json"),
    '{"id":"org.example.legacy","entry":"dist/index.mjs"}\n',
  );
  await assert.rejects(
    readPluginProject(root),
    (error) =>
      error instanceof PluginPackageError &&
      error.code === "plugin_package_legacy_unsupported",
  );
});

test("mgplugin is deterministic, excludes node_modules and rejects traversal", async (t) => {
  const root = await temporaryDirectory(t, "mgread-plugin-archive-");
  const first = join(root, "first.mgplugin");
  const second = join(root, "second.mgplugin");
  await createPluginArchive(fixtureRoot, first);
  await createPluginArchive(fixtureRoot, second);
  assert.deepEqual(await readFile(first), await readFile(second));

  const extracted = join(root, "extracted");
  const paths = await extractPluginArchive(first, extracted);
  assert.ok(paths.includes("package.json"));
  assert.ok(paths.includes("package-lock.json"));
  assert.ok(paths.includes("assets/rules.json"));
  assert.ok(paths.includes("packages/local-helper/index.js"));
  assert.equal(paths.some((path) => path.includes("node_modules")), false);
  await readPluginProject(extracted);

  const malicious = Buffer.from(await readFile(first));
  replaceAllAscii(malicious, "package.json", "../evil.json");
  const maliciousFile = join(root, "malicious.mgplugin");
  await writeFile(maliciousFile, malicious);
  await assert.rejects(
    extractPluginArchive(maliciousFile, join(root, "unsafe")),
    (error) =>
      error instanceof PluginArchiveError &&
      error.code === "plugin_archive_unsafe_path",
  );
});

test("mgplugin archive restores npm packages and manager cold-activates named exports", async (t) => {
  const dataRoot = await temporaryDirectory(t, "mgread-plugin-install-");
  const artifact = join(dataRoot, "source.mgplugin");
  await createPluginArchive(fixtureRoot, artifact);
  const installEvents = [];
  const installer = new PluginInstaller(dataRoot, {
    events: (event) => installEvents.push(event),
  });
  const installed = await installer.installArtifact(artifact);
  assert.equal(installed.pendingActivation, true);
  assert.equal(installed.reusedVersion, false);
  assert.ok(installed.hardlinkedFiles >= 2);
  assert.equal(installed.copiedFiles, 0);
  assert.deepEqual(
    installEvents.map((event) => event.code),
    ["plugin_install_started", "plugin_install_completed"],
  );

  const pluginRoot = join(
    dataRoot,
    "plugins",
    "org.mgread.runtime.fixture",
  );
  assert.equal((await readFile(join(pluginRoot, "pending"), "utf8")).trim(), "1.0.0");
  const source = await stat(
    join(pluginRoot, "versions", "1.0.0", "packages", "local-helper", "index.js"),
    { bigint: true },
  );
  const installedDependency = await stat(
    join(pluginRoot, "versions", "1.0.0", "node_modules", "local-helper", "index.js"),
    { bigint: true },
  );
  assert.equal(source.ino, installedDependency.ino);

  const managerEvents = [];
  const manager = new PluginManager(dataRoot, {
    events: (event) => managerEvents.push(event),
  });
  await manager.initialize();
  const plugins = await manager.listInstalled();
  assert.equal(plugins.length, 1);
  assert.equal(plugins[0].status, "active");
  assert.equal(plugins[0].activeVersion, "1.0.0");
  assert.equal(await fileExists(join(pluginRoot, "pending")), false);

  const search = await manager.search(
    "org.mgread.runtime.fixture",
    { query: "测试", cursor: null, pageSize: 20 },
    new AbortController().signal,
    String(Date.now() + 5_000),
  );
  assert.equal(search.items[0].title, "标准插件：测试");
  assert.equal(search.items[0].author, "org.mgread.runtime.fixture");
  assert.equal(search.items[0].wordCount, 123456);
  assert.equal(search.items[0].coverUrl, null);
  assert.deepEqual(search.items[0].tags, []);
  assert.equal(search.nextCursor, null);
  assert.equal(search.sourceName, "Runtime 标准测试数据源");
  const suggestions = await manager.searchSuggestions(
    "org.mgread.runtime.fixture",
    { cursor: null, pageSize: 20 },
    new AbortController().signal,
    String(Date.now() + 5_000),
  );
  assert.deepEqual(suggestions.items, []);
  assert.equal(suggestions.nextCursor, null);
  assert.equal(suggestions.sourceName, "Runtime 标准测试数据源");
  const discovery = await manager.discover(
    "org.mgread.runtime.fixture",
    { target: null, cursor: null, collectionId: null, pageSize: 20 },
    new AbortController().signal,
    String(Date.now() + 5_000),
  );
  const detail = await manager.getDetail(
    "org.mgread.runtime.fixture",
    { id: search.items[0].id },
    new AbortController().signal,
    String(Date.now() + 5_000),
  );
  const chapters = await manager.getChapters(
    "org.mgread.runtime.fixture",
    { id: search.items[0].id },
    new AbortController().signal,
    String(Date.now() + 5_000),
  );
  const content = await manager.getContent(
    "org.mgread.runtime.fixture",
    { id: search.items[0].id, chapterId: chapters.items[0].id },
    new AbortController().signal,
    String(Date.now() + 5_000),
  );
  assert.equal(
    discovery.document.components[1].children[0].items[0].content.title,
    "标准插件：发现",
  );
  assert.equal(detail.catalogUrl, null);
  assert.equal(chapters.items[0].order, 0);
  assert.equal(content.text, "标准插件正文。");

  const disabled = await manager.setEnabled(
    "org.mgread.runtime.fixture",
    false,
  );
  assert.equal(disabled.enabled, false);
  assert.equal(disabled.status, "disabled");
  await assert.rejects(
    manager.search(
      "org.mgread.runtime.fixture",
      { query: "测试", cursor: null, pageSize: 20 },
      new AbortController().signal,
      String(Date.now() + 5_000),
    ),
    (error) => error?.code === "plugin_disabled",
  );
  const enabled = await manager.setEnabled(
    "org.mgread.runtime.fixture",
    true,
  );
  assert.equal(enabled.enabled, true);
  assert.equal(enabled.status, "active");
  assert.equal(
    (await manager.search(
      "org.mgread.runtime.fixture",
      { query: "恢复", cursor: null, pageSize: 20 },
      new AbortController().signal,
      String(Date.now() + 5_000),
    )).items[0].title,
    "标准插件：恢复",
  );
  assert.deepEqual(
    JSON.parse(
      await readFile(
        join(dataRoot, "plugin-data", "org.mgread.runtime.fixture", "activated.json"),
        "utf8",
      ),
    ),
    { pluginApi: 1 },
  );
  assert.equal(
    managerEvents.filter((event) => event.code === "plugin_load_started").length,
    1,
  );
  assert.equal(
    managerEvents.filter((event) => event.code === "plugin_load_completed").length,
    1,
  );
  assert.equal(
    managerEvents.filter((event) => event.code === "plugin_invocation_completed").length,
    7,
  );
});

test("development projects load in place without creating an installed version", async (t) => {
  const root = await temporaryDirectory(t, "mgread-development-plugin-");
  const dataRoot = join(root, "runtime-data");
  const developmentRoot = join(root, "sources");
  const projectRoot = join(developmentRoot, "live-source");
  await createDevelopmentPlugin(projectRoot, "第一版");

  const manager = new PluginManager(dataRoot, { developmentPluginRoot: developmentRoot });
  t.after(() => manager.close());
  await manager.initialize();
  const firstList = await manager.listInstalled();
  assert.equal(firstList.length, 1);
  assert.equal(firstList[0].status, "development");
  assert.equal(firstList[0].activeVersion, "0.1.0");
  assert.equal(
    await fileExists(join(dataRoot, "plugins", "org.example.live-source")),
    false,
  );

  const directory = await manager.resolveCodeDirectory("org.example.live-source");
  assert.equal(directory.kind, "development");
  assert.equal(directory.directory, projectRoot);

  const exportable = await manager.listExportableArtifacts();
  assert.equal(exportable.length, 1);
  assert.equal(exportable[0].id, "org.example.live-source");
  assert.match(exportable[0].version, /^0\.1\.1-devsync\.\d+\.[a-f0-9]{64}$/);
  assert.equal(exportable[0].provenance, "development");
  assert.match(exportable[0].developmentFingerprint, /^[a-f0-9]{64}$/);
  assert.ok(Number.isSafeInteger(exportable[0].developmentRevision));
  const unchangedExportable = await manager.listExportableArtifacts();
  assert.equal(unchangedExportable[0].version, exportable[0].version);
  assert.equal(unchangedExportable[0].developmentFingerprint, exportable[0].developmentFingerprint);
  assert.equal(unchangedExportable[0].developmentRevision, exportable[0].developmentRevision);
  const resourceMetadata = await manager.createPluginTransferResource(
    exportable[0].id,
    exportable[0].version,
  );
  const resource = manager.consumePluginTransferResource(resourceMetadata.token);
  assert.ok(resource);
  const chunks = [];
  for await (const chunk of resource.stream) chunks.push(chunk);
  const receivedArchive = join(root, "received-development.mgplugin");
  await writeFile(receivedArchive, Buffer.concat(chunks));
  const extracted = join(root, "received-development");
  await extractPluginArchive(receivedArchive, extracted);
  const transferredPackage = JSON.parse(
    await readFile(join(extracted, "package.json"), "utf8"),
  );
  const transferredLock = JSON.parse(
    await readFile(join(extracted, "package-lock.json"), "utf8"),
  );
  assert.equal(transferredPackage.version, exportable[0].version);
  assert.equal(transferredLock.version, exportable[0].version);
  assert.equal(transferredLock.packages[""].version, exportable[0].version);

  const packaged = await manager.createDevelopmentPackageResource(
    "org.example.live-source",
  );
  assert.equal(packaged.artifact.id, "org.example.live-source");
  assert.equal(packaged.artifact.version, "0.1.0");
  assert.equal(packaged.artifact.format, "archive");
  assert.equal(packaged.artifact.provenance, "installed");
  assert.equal(packaged.artifact.developmentFingerprint, null);
  assert.equal(packaged.artifact.developmentRevision, null);
  assert.equal(
    packaged.fileName,
    "org.example.live-source-0.1.0.mgplugin",
  );
  const packagedResource = manager.consumePluginTransferResource(packaged.token);
  assert.ok(packagedResource);
  const packagedChunks = [];
  for await (const chunk of packagedResource.stream) packagedChunks.push(chunk);
  const receivedPackage = join(root, "received-development-release.mgplugin");
  await writeFile(receivedPackage, Buffer.concat(packagedChunks));
  const extractedPackage = join(root, "received-development-release");
  await extractPluginArchive(receivedPackage, extractedPackage);
  const releasedPackage = JSON.parse(
    await readFile(join(extractedPackage, "package.json"), "utf8"),
  );
  assert.equal(releasedPackage.version, "0.1.0");

  const first = await manager.search(
    "org.example.live-source",
    { query: "测试", cursor: null, pageSize: 20 },
    new AbortController().signal,
    String(Date.now() + 5_000),
  );
  assert.equal(first.items[0].title, "第一版：测试");

});

test("single-file development loads Node-resolvable external dependencies without a lockfile", async (t) => {
  const root = await temporaryDirectory(t, "mgread-single-file-development-");
  const developmentRoot = join(root, "sources");
  const projectRoot = join(developmentRoot, "external-source");
  const externalRoot = join(root, "shared-package");
  const dependencyLink = join(projectRoot, "node_modules", "@fixture", "external");
  await Promise.all([
    mkdir(join(projectRoot, "dist"), { recursive: true }),
    mkdir(join(projectRoot, "node_modules", "@fixture"), { recursive: true }),
    mkdir(externalRoot, { recursive: true }),
  ]);
  await Promise.all([
    writeFile(
      join(externalRoot, "package.json"),
      '{"name":"@fixture/external","version":"1.0.0","type":"module","exports":"./index.js"}\n',
    ),
    writeFile(join(externalRoot, "index.js"), "export const marker = 'external-loaded';\n"),
  ]);
  await symlink(externalRoot, dependencyLink, process.platform === "win32" ? "junction" : "dir");
  const packageJson = {
    name: "@mgread-plugin/external-source",
    version: "1.0.0",
    type: "module",
    main: "dist/index.mjs",
    engines: { node: ">=24 <25" },
    dependencies: { "@fixture/external": "file:../../../shared-package" },
    mgread: {
      schemaVersion: 1,
      id: "org.mgread.external-source",
      displayName: "External source",
      pluginApi: 1,
      contentKinds: ["novel"],
    },
  };
  await Promise.all([
    writeFile(join(projectRoot, "package.json"), `${JSON.stringify(packageJson, null, 2)}\n`),
    writeFile(
      join(projectRoot, "dist", "index.mjs"),
      `import { marker } from "@fixture/external";
export function activate() { if (marker !== "external-loaded") throw new Error("external dependency missing"); }
export function discover() { return { kind: "document", document: { components: [] } }; }
export function search() { return { items: [], nextCursor: null, totalCount: 0 }; }
export function getDetail() { throw new Error("unused"); }
export function getChapters() { return { items: [] }; }
export function getContent() { throw new Error("unused"); }
`,
    ),
  ]);

  const project = await readPluginProject(projectRoot);
  assert.equal(project.descriptor.packageMode, "single-file");
  assert.deepEqual(project.dependencies, []);
  assert.deepEqual(project.lock, {});

  const manager = new PluginManager(join(root, "runtime"), {
    developmentPluginRoot: developmentRoot,
  });
  await manager.initialize();
  assert.deepEqual(
    (await manager.listInstalled()).map((plugin) => plugin.id),
    ["org.mgread.external-source"],
  );
});

test("archive projects still reject external local dependency restoration", async (t) => {
  const root = await temporaryDirectory(t, "mgread-archive-external-dependency-");
  await cp(fixtureRoot, root, { recursive: true });
  const packagePath = join(root, "package.json");
  const lockPath = join(root, "package-lock.json");
  const packageJson = JSON.parse(await readFile(packagePath, "utf8"));
  const lock = JSON.parse(await readFile(lockPath, "utf8"));
  packageJson.dependencies = { "local-helper": "file:../../../shared-package" };
  lock.packages[""].dependencies = packageJson.dependencies;
  lock.packages["node_modules/local-helper"].resolved = "../../../shared-package";
  await Promise.all([
    writeFile(packagePath, `${JSON.stringify(packageJson, null, 2)}\n`),
    writeFile(lockPath, `${JSON.stringify(lock, null, 2)}\n`),
  ]);
  await assert.rejects(
    readPluginProject(root),
    (error) =>
      error instanceof PluginPackageError &&
      error.code === "plugin_package_unsupported_dependency",
  );
});

test("Runtime calls reuse the current development snapshot without rescanning directories", async (t) => {
  const root = await temporaryDirectory(t, "mgread-development-cache-usage-");
  const dataRoot = join(root, "runtime-data");
  const developmentRoot = join(root, "sources");
  await createDevelopmentPlugin(join(developmentRoot, "first-source"), "第一版");
  const manager = new PluginManager(dataRoot, { developmentPluginRoot: developmentRoot });
  t.after(() => manager.close());
  await manager.initialize();

  const laterRoot = join(developmentRoot, "later-source");
  await createDevelopmentPlugin(laterRoot, "后加入");
  const laterPackagePath = join(laterRoot, "package.json");
  const laterPackage = JSON.parse(await readFile(laterPackagePath, "utf8"));
  laterPackage.mgread.id = "org.example.live-source-later";
  await writeFile(laterPackagePath, `${JSON.stringify(laterPackage, null, 2)}\n`);

  assert.deepEqual(await manager.listCacheUsage("org.example.live-source-later"), []);
  assert.deepEqual(await manager.listCacheUsage("org.example.live-source-later"), []);
  const refreshed = await manager.listCacheUsage();
  assert.deepEqual(
    refreshed.map((usage) => usage.pluginId).sort(),
    ["org.example.live-source"],
  );
});

test("development transfer trusts the package tool artifact without Runtime revalidation", async (t) => {
  const root = await temporaryDirectory(t, "mgread-trusted-development-artifact-");
  const dataRoot = join(root, "runtime-data");
  const developmentRoot = join(root, "sources");
  const projectRoot = join(developmentRoot, "live-source");
  await createDevelopmentPlugin(projectRoot, "可信构建结果");
  await writeFile(
    join(projectRoot, "tools", "mgread.mjs"),
    `export function buildPluginArtifact({ versionOverride }) {
  return {
    bytes: Uint8Array.from([0x74, 0x72, 0x75, 0x73, 0x74, 0x65, 0x64]),
    fileName: "trusted.mgplugin",
    format: "archive",
    versionOverride,
  };
}
`,
  );

  const manager = new PluginManager(dataRoot, { developmentPluginRoot: developmentRoot });
  t.after(() => manager.close());
  await manager.initialize();

  const exportable = await manager.listExportableArtifacts();
  assert.deepEqual(exportable.map(({ id, format, bytes }) => ({ id, format, bytes })), [
    { id: "org.example.live-source", format: "archive", bytes: 7 },
  ]);
});

test("a development project shadows an installed archive with the same ID without double activation", async (t) => {
  const root = await temporaryDirectory(t, "mgread-development-shadow-");
  const dataRoot = join(root, "runtime-data");
  const developmentRoot = join(root, "sources");
  const projectRoot = join(developmentRoot, "same-source");
  await new PluginInstaller(dataRoot).installProject(fixtureRoot);
  await createDevelopmentPlugin(projectRoot, "开发覆盖");
  const developmentPackage = JSON.parse(await readFile(join(projectRoot, "package.json"), "utf8"));
  developmentPackage.mgread.id = "org.mgread.runtime.fixture";
  await writeFile(join(projectRoot, "package.json"), `${JSON.stringify(developmentPackage, null, 2)}\n`);

  const events = [];
  const development = new PluginManager(dataRoot, {
    developmentPluginRoot: developmentRoot,
    events: (event) => events.push(event),
  });
  t.after(() => development.close());
  await development.initialize();
  const active = await development.listInstalled();
  assert.equal(active.length, 1);
  assert.equal(active[0].id, "org.mgread.runtime.fixture");
  assert.equal(active[0].status, "development");
  assert.equal(events.filter((event) => event.code === "plugin_load_started").length, 1);

  await development.close();
  await rm(projectRoot, { force: true, recursive: true });
  const installed = new PluginManager(dataRoot);
  t.after(() => installed.close());
  await installed.initialize();
  const fallback = await installed.listInstalled();
  assert.equal(fallback.length, 1);
  assert.equal(fallback[0].status, "active");
});
