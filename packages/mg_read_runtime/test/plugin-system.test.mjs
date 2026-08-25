import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  cp,
  mkdtemp,
  mkdir,
  readFile,
  rm,
  stat,
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

test("installer hardlinks local packages and manager cold-activates named exports", async (t) => {
  const dataRoot = await temporaryDirectory(t, "mgread-plugin-install-");
  const installEvents = [];
  const installer = new PluginInstaller(dataRoot, {
    events: (event) => installEvents.push(event),
  });
  const installed = await installer.installProject(fixtureRoot);
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
  assert.equal(search.sourceName, "Runtime 标准测试书源");
  const suggestions = await manager.searchSuggestions(
    "org.mgread.runtime.fixture",
    { cursor: null, pageSize: 20 },
    new AbortController().signal,
    String(Date.now() + 5_000),
  );
  assert.deepEqual(suggestions.items, []);
  assert.equal(suggestions.nextCursor, null);
  assert.equal(suggestions.sourceName, "Runtime 标准测试书源");
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

  const exportable = await manager.listExportableArchives();
  assert.equal(exportable.length, 1);
  assert.equal(exportable[0].id, "org.example.live-source");
  assert.match(exportable[0].version, /^0\.1\.1-devsync\.\d+$/);
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

  const first = await manager.search(
    "org.example.live-source",
    { query: "测试", cursor: null, pageSize: 20 },
    new AbortController().signal,
    String(Date.now() + 5_000),
  );
  assert.equal(first.items[0].title, "第一版：测试");

});

test("content v1 requires explicit null keys and preserves zero and empty arrays", () => {
  const summary = {
    id: "book:null-semantics",
    title: "空值语义",
    contentKind: "novel",
    author: null,
    url: null,
    coverUrl: null,
    description: null,
    language: null,
    status: "unknown",
    access: "unknown",
    wordCount: 0,
    chapterCount: 0,
    publishedAt: null,
    updatedAt: null,
    latestChapter: null,
    categories: [],
    tags: [],
    attributes: [],
  };
  const result = validateSearchResult("org.example.nulls", "空值书源", {
    items: [summary],
    nextCursor: null,
    totalCount: 0,
  });
  assert.equal(result.items[0].author, null);
  assert.equal(result.items[0].wordCount, 0);
  assert.deepEqual(result.items[0].categories, []);

  const { author: _author, ...missingAuthor } = summary;
  assert.throws(
    () =>
      validateSearchResult("org.example.nulls", "空值书源", {
        items: [missingAuthor],
        nextCursor: null,
        totalCount: 0,
      }),
    PluginContentValidationError,
  );
  assert.throws(
    () =>
      validateSearchResult("org.example.nulls", "空值书源", {
        items: [{ ...summary, author: "" }],
        nextCursor: null,
        totalCount: 0,
      }),
    PluginContentValidationError,
  );
  assert.throws(
    () =>
      validateSearchResult("org.example.nulls", "空值书源", {
        items: [{ ...summary, tags: null }],
        nextCursor: null,
        totalCount: 0,
      }),
    PluginContentValidationError,
  );

  const discovery = validateDiscoverResult("org.example.nulls", "空值书源", {
    kind: "document",
    document: { components: [] },
  });
  assert.equal(discovery.kind, "document");
  assert.deepEqual(discovery.document.components, []);

  const detail = validateDetailResult("org.example.nulls", "空值书源", {
    ...summary,
    aliases: [],
    catalogUrl: null,
  });
  assert.deepEqual(detail.aliases, []);
  assert.equal(detail.catalogUrl, null);

  const chapters = validateChaptersResult("org.example.nulls", "空值书源", {
    items: [
      {
        id: "chapter:zero",
        title: "零字章节",
        order: 0,
        url: null,
        volumeTitle: null,
        wordCount: 0,
        updatedAt: null,
        isLocked: null,
        attributes: [],
      },
    ],
  });
  assert.equal(chapters.items[0].wordCount, 0);
  assert.equal(chapters.items[0].isLocked, null);
  assert.deepEqual(chapters.items[0].attributes, []);

  const novelContent = validateContentResult("org.example.nulls", "空值书源", {
    contentKind: "novel",
    chapterId: "chapter:zero",
    title: null,
    updatedAt: null,
    text: "",
    pages: [],
  });
  assert.equal(novelContent.title, null);
  assert.equal(novelContent.text, "");
  assert.deepEqual(novelContent.pages, []);

  const mangaContent = validateContentResult("org.example.nulls", "空值书源", {
    contentKind: "manga",
    chapterId: "chapter:manga",
    title: null,
    updatedAt: null,
    text: null,
    pages: [
      {
        id: "page:0",
        index: 0,
        url: "https://example.invalid/page/0",
        mimeType: null,
        width: null,
        height: null,
      },
    ],
  });
  assert.equal(mangaContent.text, null);
  assert.equal(mangaContent.pages[0].mimeType, null);
  assert.equal(mangaContent.pages[0].width, null);

  assert.throws(
    () =>
      validateSearchResult("org.example.nulls", "空值书源", {
        items: [
          {
            ...summary,
            latestChapter: {
              title: "缺少固定 nullable 键",
              url: null,
              updatedAt: null,
            },
          },
        ],
        nextCursor: null,
        totalCount: 0,
      }),
    PluginContentValidationError,
  );
  assert.throws(
    () =>
      validateSearchResult("org.example.nulls", "空值书源", {
        items: [summary, summary],
        nextCursor: null,
        totalCount: 2,
      }),
    PluginContentValidationError,
  );
  assert.throws(
    () =>
      validateContentResult("org.example.nulls", "空值书源", {
        contentKind: "manga",
        chapterId: "chapter:manga",
        title: null,
        updatedAt: null,
        text: null,
        pages: [
          {
            id: "page:wrong-index",
            index: 1,
            url: "https://example.invalid/page/1",
            mimeType: null,
            width: null,
            height: null,
          },
        ],
      }),
    PluginContentValidationError,
  );
});

test("complete chapter catalogs enforce count, byte, uniqueness, and shape limits", () => {
  assert.deepEqual(
    parseChaptersParams({ pluginId: "org.example.catalog", id: "book:1" }),
    { pluginId: "org.example.catalog", request: { id: "book:1" } },
  );
  assert.throws(
    () =>
      parseChaptersParams({
        pluginId: "org.example.catalog",
        id: "book:1",
        cursor: null,
        pageSize: 20,
      }),
    PluginContentValidationError,
  );
  const chapter = (index, idPrefix = "chapter") => ({
    id: `${idPrefix}:${index}`,
    title: `第${index + 1}章`,
    order: index,
    url: null,
    volumeTitle: null,
    wordCount: null,
    updatedAt: null,
    isLocked: false,
    attributes: [],
  });
  const maximum = Array.from({ length: 5_000 }, (_, index) => chapter(index));
  assert.equal(
    validateChaptersResult("org.example.catalog", "完整目录", { items: maximum })
      .items.length,
    5_000,
  );
  assert.throws(
    () =>
      validateChaptersResult("org.example.catalog", "完整目录", {
        items: [...maximum, chapter(5_000)],
      }),
    PluginContentValidationError,
  );
  assert.throws(
    () =>
      validateChaptersResult("org.example.catalog", "完整目录", {
        items: [chapter(0), { ...chapter(1), id: chapter(0).id }],
      }),
    PluginContentValidationError,
  );
  const oversized = Array.from({ length: 4_500 }, (_, index) =>
    chapter(index, `chapter:${"x".repeat(480)}`),
  );
  assert.throws(
    () =>
      validateChaptersResult("org.example.catalog", "完整目录", {
        items: oversized,
      }),
    PluginContentValidationError,
  );
  assert.throws(
    () =>
      validateChaptersResult("org.example.catalog", "完整目录", {
        items: [chapter(0)],
        nextCursor: null,
      }),
    PluginContentValidationError,
  );
});

test("registry dependencies are verified, shared once, copied on hardlink failure and swept", async (t) => {
  const dataRoot = await temporaryDirectory(t, "mgread-dependency-store-");
  const tarball = makeNpmTarball({
    "package.json": JSON.stringify({
      name: "fixture-dependency",
      version: "1.0.0",
      type: "module",
      main: "index.js",
    }),
    "index.js": "export const suffix = '共享依赖';\n",
    "data/rules.json": "{\"enabled\":true}\n",
    "wasm/parser.wasm": Buffer.from([0, 97, 115, 109]),
  });
  const integrity = `sha512-${createHash("sha512").update(tarball).digest("base64")}`;
  let downloads = 0;
  const fetchPackage = async () => {
    downloads += 1;
    return {
      ok: true,
      status: 200,
      async arrayBuffer() {
        return tarball.buffer.slice(
          tarball.byteOffset,
          tarball.byteOffset + tarball.byteLength,
        );
      },
    };
  };
  const store = new DependencyStore(dataRoot, { fetchPackage });
  const installer = new PluginInstaller(dataRoot, { dependencyStore: store });
  const firstProject = await createRegistryPlugin(
    join(dataRoot, "project-a"),
    "org.example.registry.a",
    "@mgread-plugin/registry-a",
    integrity,
  );
  const secondProject = await createRegistryPlugin(
    join(dataRoot, "project-b"),
    "org.example.registry.b",
    "@mgread-plugin/registry-b",
    integrity,
  );
  const [first, second] = await Promise.all([
    installer.installProject(firstProject),
    installer.installProject(secondProject),
  ]);
  assert.equal(downloads, 1);
  assert.ok(first.hardlinkedFiles >= 4);
  assert.ok(second.hardlinkedFiles >= 4);
  assert.equal(
    await readFile(
      join(
        dataRoot,
        "plugins",
        "org.example.registry.a",
        "versions",
        "1.0.0",
        "node_modules",
        "fixture-dependency",
        "data",
        "rules.json",
      ),
      "utf8",
    ),
    '{"enabled":true}\n',
  );
  assert.deepEqual(
    await readFile(
      join(
        dataRoot,
        "plugins",
        "org.example.registry.a",
        "versions",
        "1.0.0",
        "node_modules",
        "fixture-dependency",
        "wasm",
        "parser.wasm",
      ),
    ),
    Buffer.from([0, 97, 115, 109]),
  );
  assert.equal((await installer.collectUnusedDependencies()).removedObjects, 0);

  await installer.scheduleUninstall("org.example.registry.a");
  await installer.scheduleUninstall("org.example.registry.b");
  await new PluginManager(dataRoot).initialize();
  assert.equal((await installer.collectUnusedDependencies()).removedObjects, 1);

  const copyRoot = await temporaryDirectory(t, "mgread-dependency-copy-");
  const copyStore = new DependencyStore(copyRoot, {
    fetchPackage,
    hardlinkFile: async () => {
      throw Object.assign(new Error("hardlink unavailable"), { code: "EPERM" });
    },
  });
  const copyInstaller = new PluginInstaller(copyRoot, {
    dependencyStore: copyStore,
  });
  const copyProject = await createRegistryPlugin(
    join(copyRoot, "project"),
    "org.example.registry.copy",
    "@mgread-plugin/registry-copy",
    integrity,
  );
  const copied = await copyInstaller.installProject(copyProject);
  assert.equal(copied.hardlinkedFiles, 0);
  assert.ok(copied.copiedFiles >= 4);
});

test("integrity failure produces one install terminal and leaves no version", async (t) => {
  const dataRoot = await temporaryDirectory(t, "mgread-integrity-failure-");
  const tarball = makeNpmTarball({
    "package.json": "{\"name\":\"bad\",\"version\":\"1.0.0\"}",
    "index.js": "export {};\n",
  });
  const events = [];
  const store = new DependencyStore(dataRoot, {
    fetchPackage: async () => ({
      ok: true,
      status: 200,
      async arrayBuffer() {
        return tarball.buffer.slice(
          tarball.byteOffset,
          tarball.byteOffset + tarball.byteLength,
        );
      },
    }),
  });
  const installer = new PluginInstaller(dataRoot, {
    dependencyStore: store,
    events: (event) => events.push(event),
  });
  const project = await createRegistryPlugin(
    join(dataRoot, "project"),
    "org.example.integrity",
    "@mgread-plugin/integrity",
    `sha512-${Buffer.alloc(64).toString("base64")}`,
  );
  await assert.rejects(installer.installProject(project));
  assert.deepEqual(
    events.map((event) => event.code),
    ["plugin_install_started", "plugin_install_failed"],
  );
  assert.equal(
    await fileExists(
      join(dataRoot, "plugins", "org.example.integrity", "versions", "1.0.0"),
    ),
    false,
  );
});

test("a legacy default-export pending update fails and keeps current active", async (t) => {
  const dataRoot = await temporaryDirectory(t, "mgread-plugin-rollback-");
  const installer = new PluginInstaller(dataRoot);
  await installer.installProject(fixtureRoot);
  await new PluginManager(dataRoot).initialize();

  const updateRoot = join(dataRoot, "update-project");
  await cp(fixtureRoot, updateRoot, { recursive: true });
  const packageJson = JSON.parse(
    await readFile(join(updateRoot, "package.json"), "utf8"),
  );
  const lockfile = JSON.parse(
    await readFile(join(updateRoot, "package-lock.json"), "utf8"),
  );
  packageJson.version = "2.0.0";
  lockfile.version = "2.0.0";
  lockfile.packages[""].version = "2.0.0";
  await Promise.all([
    writeFile(
      join(updateRoot, "package.json"),
      `${JSON.stringify(packageJson, null, 2)}\n`,
    ),
    writeFile(
      join(updateRoot, "package-lock.json"),
      `${JSON.stringify(lockfile, null, 2)}\n`,
    ),
    writeFile(
      join(updateRoot, "dist", "index.mjs"),
      "export default { async search(keyword) { return [{ id: keyword, title: keyword }]; } };\n",
    ),
  ]);
  await installer.installProject(updateRoot);

  const events = [];
  const manager = new PluginManager(dataRoot, {
    events: (event) => events.push(event),
  });
  await manager.initialize();
  const plugin = (await manager.listInstalled())[0];
  assert.equal(plugin.status, "active");
  assert.equal(plugin.activeVersion, "1.0.0");
  assert.equal(plugin.pendingVersion, null);
  const pluginRoot = join(dataRoot, "plugins", "org.mgread.runtime.fixture");
  assert.equal((await readFile(join(pluginRoot, "current"), "utf8")).trim(), "1.0.0");
  assert.equal((await readFile(join(pluginRoot, "failed"), "utf8")).trim(), "2.0.0");
  assert.equal(
    events.filter((event) => event.code === "plugin_load_failed").length,
    1,
  );
  assert.equal(
    events.filter((event) => event.code === "plugin_load_completed").length,
    1,
  );
});

test("a broken current source is quarantined without blocking other sources", async (t) => {
  const dataRoot = await temporaryDirectory(t, "mgread-plugin-quarantine-");
  const installer = new PluginInstaller(dataRoot);
  await installer.installProject(fixtureRoot);

  const brokenRoot = join(dataRoot, "broken-project");
  await cp(fixtureRoot, brokenRoot, { recursive: true });
  const packageJson = JSON.parse(await readFile(join(brokenRoot, "package.json"), "utf8"));
  const lockfile = JSON.parse(await readFile(join(brokenRoot, "package-lock.json"), "utf8"));
  packageJson.name = "@mgread-plugin/broken-fixture";
  packageJson.mgread.id = "org.mgread.runtime.broken";
  packageJson.mgread.displayName = "Broken fixture";
  lockfile.name = packageJson.name;
  lockfile.packages[""].name = packageJson.name;
  await Promise.all([
    writeFile(join(brokenRoot, "package.json"), `${JSON.stringify(packageJson, null, 2)}\n`),
    writeFile(join(brokenRoot, "package-lock.json"), `${JSON.stringify(lockfile, null, 2)}\n`),
    writeFile(join(brokenRoot, "dist", "index.mjs"), "export const broken = ;\n"),
  ]);
  await installer.installProject(brokenRoot);

  const manager = new PluginManager(dataRoot);
  await manager.initialize();
  const first = await manager.listInstalled();
  const broken = first.find((item) => item.id === "org.mgread.runtime.broken");
  assert.equal(broken?.enabled, false);
  assert.equal(broken?.status, "quarantined");
  assert.equal(
    (await manager.search(
      "org.mgread.runtime.fixture",
      { query: "隔离后仍可用", cursor: null, pageSize: 20 },
      new AbortController().signal,
      String(Date.now() + 5_000),
    )).items[0].title,
    "标准插件：隔离后仍可用",
  );
  assert.deepEqual(await manager.consumeStartupRecovery(), { quarantinedCount: 1 });
  assert.deepEqual(await manager.consumeStartupRecovery(), { quarantinedCount: 0 });

  const marker = join(dataRoot, "plugins", "org.mgread.runtime.broken", "quarantined");
  assert.equal((await readFile(marker, "utf8")).trim(), "1.0.0");
  const restarted = new PluginManager(dataRoot);
  await restarted.initialize();
  assert.equal(
    (await restarted.listInstalled()).find((item) => item.id === "org.mgread.runtime.broken")?.status,
    "quarantined",
  );
  assert.deepEqual(await restarted.consumeStartupRecovery(), { quarantinedCount: 0 });

  packageJson.version = "2.0.0";
  lockfile.version = "2.0.0";
  lockfile.packages[""].version = "2.0.0";
  await Promise.all([
    writeFile(join(brokenRoot, "package.json"), `${JSON.stringify(packageJson, null, 2)}\n`),
    writeFile(join(brokenRoot, "package-lock.json"), `${JSON.stringify(lockfile, null, 2)}\n`),
    cp(join(fixtureRoot, "dist", "index.mjs"), join(brokenRoot, "dist", "index.mjs")),
  ]);
  await installer.installProject(brokenRoot);
  const recovered = new PluginManager(dataRoot);
  await recovered.initialize();
  const recoveredSource = (await recovered.listInstalled()).find(
    (item) => item.id === "org.mgread.runtime.broken",
  );
  assert.equal(recoveredSource?.status, "active");
  assert.equal(recoveredSource?.activeVersion, "2.0.0");
  assert.equal(await fileExists(marker), false);
});

test("plugin calls give cancel and timeout exactly one terminal event", async (t) => {
  const dataRoot = await temporaryDirectory(t, "mgread-plugin-cancel-");
  const project = await createDelayedPlugin(join(dataRoot, "project"));
  await new PluginInstaller(dataRoot).installProject(project);
  const events = [];
  const manager = new PluginManager(dataRoot, {
    events: (event) => events.push(event),
  });
  await manager.initialize();

  const controller = new AbortController();
  const cancelled = manager.search(
    "org.example.delayed",
    { query: "cancel", cursor: null, pageSize: 20 },
    controller.signal,
    String(Date.now() + 5_000),
  );
  setTimeout(() => controller.abort(), 5);
  await assert.rejects(cancelled, (error) => error?.code === "cancelled");

  await assert.rejects(
    manager.search(
      "org.example.delayed",
      { query: "timeout", cursor: null, pageSize: 20 },
      new AbortController().signal,
      String(Date.now() - 1),
    ),
    (error) => error?.code === "timeout",
  );
  assert.equal(
    events.filter((event) => event.code === "plugin_invocation_started").length,
    2,
  );
  assert.equal(
    events.filter((event) => event.code === "plugin_invocation_failed").length,
    2,
  );
  assert.equal(
    events.filter((event) => event.code === "plugin_invocation_completed").length,
    0,
  );
});

test("plugin execution failures stay distinct from invalid plugin responses", async (t) => {
  const dataRoot = await temporaryDirectory(t, "mgread-plugin-execution-failure-");
  const project = await createDelayedPlugin(join(dataRoot, "project"));
  await new PluginInstaller(dataRoot).installProject(project);
  const events = [];
  const manager = new PluginManager(dataRoot, {
    events: (event) => events.push(event),
  });
  await manager.initialize();

  await assert.rejects(
    manager.getDetail(
      "org.example.delayed",
      { id: "opaque:secret-canary-not-diagnostic" },
      new AbortController().signal,
      String(Date.now() + 5_000),
    ),
    (error) => error?.code === "plugin_execution_failed",
  );
  assert.equal(
    events.filter((event) => event.code === "plugin_invocation_failed").length,
    1,
  );
});

test("an unavailable optional dependency is skipped without changing install success", async (t) => {
  const dataRoot = await temporaryDirectory(t, "mgread-plugin-optional-");
  const integrity = `sha512-${Buffer.alloc(64).toString("base64")}`;
  const project = await createRegistryPlugin(
    join(dataRoot, "project"),
    "org.example.optional",
    "@mgread-plugin/optional",
    integrity,
    { optional: true },
  );
  const store = new DependencyStore(dataRoot, {
    fetchPackage: async () => ({
      ok: false,
      status: 503,
      async arrayBuffer() {
        return new ArrayBuffer(0);
      },
    }),
  });
  const result = await new PluginInstaller(dataRoot, {
    dependencyStore: store,
  }).installProject(project);
  assert.equal(result.skippedOptionalDependencies, 1);
  assert.equal(result.pendingActivation, true);
});

async function createRegistryPlugin(
  root,
  id,
  name,
  integrity,
  { optional = false } = {},
) {
  await mkdir(join(root, "dist"), { recursive: true });
  const dependencyField = optional ? "optionalDependencies" : "dependencies";
  const packageJson = {
    name,
    version: "1.0.0",
    type: "module",
    main: "dist/index.mjs",
    engines: { node: ">=24 <25" },
    [dependencyField]: { "fixture-dependency": "1.0.0" },
    mgread: {
      schemaVersion: 1,
      id,
      displayName: `Fixture ${id}`,
      pluginApi: 1,
      contentKinds: ["novel"],
    },
  };
  const lock = {
    name,
    version: "1.0.0",
    lockfileVersion: 3,
    requires: true,
    packages: {
      "": {
        name,
        version: "1.0.0",
        [dependencyField]: { "fixture-dependency": "1.0.0" },
      },
      "node_modules/fixture-dependency": {
        version: "1.0.0",
        resolved:
          "https://registry.npmjs.org/fixture-dependency/-/fixture-dependency-1.0.0.tgz",
        integrity,
        ...(optional ? { optional: true } : {}),
      },
    },
  };
  await Promise.all([
    writeFile(join(root, "package.json"), `${JSON.stringify(packageJson, null, 2)}\n`),
    writeFile(join(root, "package-lock.json"), `${JSON.stringify(lock, null, 2)}\n`),
    writeFile(
      join(root, "dist", "index.mjs"),
      "export async function search(keyword) { return [{ id: keyword, title: keyword }]; }\n",
    ),
  ]);
  return root;
}

async function createDelayedPlugin(root) {
  await mkdir(join(root, "dist"), { recursive: true });
  const packageJson = {
    name: "@mgread-plugin/delayed",
    version: "1.0.0",
    type: "module",
    main: "dist/index.mjs",
    engines: { node: ">=24 <25" },
    mgread: {
      schemaVersion: 1,
      id: "org.example.delayed",
      displayName: "Delayed fixture",
      pluginApi: 1,
      contentKinds: ["novel"],
    },
  };
  const lock = {
    name: packageJson.name,
    version: packageJson.version,
    lockfileVersion: 3,
    requires: true,
    packages: {
      "": {
        name: packageJson.name,
        version: packageJson.version,
      },
    },
  };
  await Promise.all([
    writeFile(
      join(root, "package.json"),
      `${JSON.stringify(packageJson, null, 2)}\n`,
    ),
    writeFile(
      join(root, "package-lock.json"),
      `${JSON.stringify(lock, null, 2)}\n`,
    ),
    writeFile(
      join(root, "dist", "index.mjs"),
      `export function activate() {}
export function discover() { return { kind: "document", document: { components: [] } }; }
export async function search() { await new Promise((resolve) => setTimeout(resolve, 40)); return { items: [], nextCursor: null, totalCount: 0 }; }
export function getDetail() { throw new Error("unused"); }
export function getChapters() { throw new Error("unused"); }
export function getContent() { throw new Error("unused"); }
`,
    ),
  ]);
  return root;
}

async function createDevelopmentPlugin(root, prefix) {
  await mkdir(join(root, "dist"), { recursive: true });
  const packageJson = {
    name: "@mgread-plugin/live-source",
    version: "0.1.0",
    type: "module",
    main: "dist/index.mjs",
    engines: { node: ">=24 <25" },
    mgread: {
      schemaVersion: 1,
      id: "org.example.live-source",
      displayName: "Live source",
      pluginApi: 1,
      contentKinds: ["novel"],
    },
  };
  const lock = {
    name: packageJson.name,
    version: packageJson.version,
    lockfileVersion: 3,
    requires: true,
    packages: {
      "": { name: packageJson.name, version: packageJson.version },
    },
  };
  const entry = `
export function activate() {}
const summary = (query) => ({
  id: "live:" + query,
  title: ${JSON.stringify(prefix)} + "：" + query,
  contentKind: "novel",
  author: null,
  url: null,
  coverUrl: null,
  description: null,
  language: null,
  status: "unknown",
  access: "unknown",
  wordCount: null,
  chapterCount: 0,
  publishedAt: null,
  updatedAt: null,
  latestChapter: null,
  categories: [],
  tags: [],
  attributes: [],
});
export function discover() { return { kind: "document", document: { components: [] } }; }
export function search(request) { return { items: [summary(request.query)], nextCursor: null, totalCount: 1 }; }
export function getDetail(request) { return { ...summary(request.id), id: request.id, aliases: [], catalogUrl: null }; }
export function getChapters() { return { items: [] }; }
export function getContent(request) { return { contentKind: "novel", chapterId: request.chapterId, title: null, updatedAt: null, text: "text", pages: [] }; }
`;
  await Promise.all([
    writeFile(join(root, "package.json"), `${JSON.stringify(packageJson, null, 2)}\n`),
    writeFile(join(root, "package-lock.json"), `${JSON.stringify(lock, null, 2)}\n`),
    writeFile(join(root, "dist", "index.mjs"), entry),
  ]);
  return root;
}

function makeNpmTarball(files) {
  const parts = [];
  for (const [path, value] of Object.entries(files)) {
    const bytes = Buffer.isBuffer(value) ? value : Buffer.from(value);
    const header = Buffer.alloc(512);
    writeTarString(header, 0, 100, `package/${path}`);
    writeTarOctal(header, 100, 8, 0o444);
    writeTarOctal(header, 108, 8, 0);
    writeTarOctal(header, 116, 8, 0);
    writeTarOctal(header, 124, 12, bytes.length);
    writeTarOctal(header, 136, 12, 0);
    header.fill(0x20, 148, 156);
    header[156] = "0".charCodeAt(0);
    writeTarString(header, 257, 6, "ustar");
    writeTarString(header, 263, 2, "00");
    let checksum = 0;
    for (const byte of header) checksum += byte;
    const checksumText = checksum.toString(8).padStart(6, "0");
    header.write(checksumText, 148, 6, "ascii");
    header[154] = 0;
    header[155] = 0x20;
    const padding = Buffer.alloc((512 - (bytes.length % 512)) % 512);
    parts.push(header, bytes, padding);
  }
  parts.push(Buffer.alloc(1024));
  return gzipSync(Buffer.concat(parts), { level: 9, mtime: 0 });
}

function writeTarString(buffer, offset, length, value) {
  const bytes = Buffer.from(value);
  assert.ok(bytes.length <= length);
  bytes.copy(buffer, offset);
}

function writeTarOctal(buffer, offset, length, value) {
  const text = value.toString(8).padStart(length - 1, "0") + "\0";
  buffer.write(text, offset, length, "ascii");
}

function replaceAllAscii(buffer, from, to) {
  assert.equal(Buffer.byteLength(from), Buffer.byteLength(to));
  const source = Buffer.from(from);
  const replacement = Buffer.from(to);
  let offset = 0;
  let replacements = 0;
  while ((offset = buffer.indexOf(source, offset)) >= 0) {
    replacement.copy(buffer, offset);
    replacements += 1;
    offset += replacement.length;
  }
  assert.ok(replacements >= 2);
}

async function fileExists(path) {
  try {
    await stat(path);
    return true;
  } catch {
    return false;
  }
}
