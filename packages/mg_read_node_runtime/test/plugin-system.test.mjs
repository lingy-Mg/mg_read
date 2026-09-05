import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  chmod,
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
  PluginBrowserSessionError,
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
const mangaFixtureRoot = fileURLToPath(
  new URL("./fixtures/manga-plugin/", import.meta.url),
);

async function temporaryDirectory(t, prefix) {
  const root = await mkdtemp(join(tmpdir(), prefix));
  t.after(() => rm(root, { force: true, recursive: true }));
  return root;
}

async function waitFor(predicate, timeoutMs = 500) {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error("Timed out waiting for plugin terminal event.");
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}


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
  const result = validateSearchResult("org.example.nulls", "空值数据源", {
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
      validateSearchResult("org.example.nulls", "空值数据源", {
        items: [missingAuthor],
        nextCursor: null,
        totalCount: 0,
      }),
    PluginContentValidationError,
  );
  assert.throws(
    () =>
      validateSearchResult("org.example.nulls", "空值数据源", {
        items: [{ ...summary, author: "" }],
        nextCursor: null,
        totalCount: 0,
      }),
    PluginContentValidationError,
  );
  assert.throws(
    () =>
      validateSearchResult("org.example.nulls", "空值数据源", {
        items: [{ ...summary, tags: null }],
        nextCursor: null,
        totalCount: 0,
      }),
    PluginContentValidationError,
  );

  const discovery = validateDiscoverResult("org.example.nulls", "空值数据源", {
    kind: "document",
    document: { components: [] },
  });
  assert.equal(discovery.kind, "document");
  assert.deepEqual(discovery.document.components, []);

  const detail = validateDetailResult("org.example.nulls", "空值数据源", {
    ...summary,
    aliases: [],
    catalogUrl: null,
  });
  assert.deepEqual(detail.aliases, []);
  assert.equal(detail.catalogUrl, null);

  const chapters = validateChaptersResult("org.example.nulls", "空值数据源", {
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

  const novelContent = validateContentResult("org.example.nulls", "空值数据源", {
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

  const mangaContent = validateContentResult("org.example.nulls", "空值数据源", {
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
  assert.equal(mangaContent.pages[0].resourcePolicy, "sessionOnly");
  assert.equal(mangaContent.pages[0].expiresAt, null);

  for (const [resourcePolicy, expiresAt] of [["sessionOnly", null], ["refreshable", "2026-08-28T00:00:00Z"], ["durable", null]]) {
    const page = { id: `page:${resourcePolicy}`, index: 0, url: "https://example.invalid/page/0", mimeType: null, width: null, height: null, resourcePolicy, expiresAt };
    assert.equal(validateContentResult("org.example.nulls", "空值数据源", { contentKind: "manga", chapterId: "chapter:policy", title: null, updatedAt: null, text: null, pages: [page] }).pages[0].resourcePolicy, resourcePolicy);
  }
  assert.throws(() => validateContentResult("org.example.nulls", "空值数据源", { contentKind: "manga", chapterId: "chapter:bad", title: null, updatedAt: null, text: null, pages: [{ id: "page:bad", index: 0, url: "https://example.invalid/page/0", mimeType: null, width: null, height: null, resourcePolicy: "refreshable", expiresAt: null }] }), PluginContentValidationError);
  const underManifestBudget = Array.from({ length: 60 }, (_, index) => ({ id: `page:${index}:${"x".repeat(8180)}`, index, url: "https://example.invalid/page/0", mimeType: null, width: null, height: null }));
  assert.equal(validateContentResult("org.example.nulls", "空值数据源", { contentKind: "manga", chapterId: "chapter:budget", title: null, updatedAt: null, text: null, pages: underManifestBudget }).pages.length, 60);
  const overManifestBudget = Array.from({ length: 63 }, (_, index) => ({ id: `page:${index}:${"x".repeat(8180)}`, index, url: "https://example.invalid/page/0", mimeType: null, width: null, height: null }));
  assert.throws(() => validateContentResult("org.example.nulls", "空值数据源", { contentKind: "manga", chapterId: "chapter:budget", title: null, updatedAt: null, text: null, pages: overManifestBudget }), PluginContentValidationError);

  assert.throws(
    () =>
      validateSearchResult("org.example.nulls", "空值数据源", {
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
      validateSearchResult("org.example.nulls", "空值数据源", {
        items: [summary, summary],
        nextCursor: null,
        totalCount: 2,
      }),
    PluginContentValidationError,
  );
  assert.throws(
    () =>
      validateContentResult("org.example.nulls", "空值数据源", {
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

test("installed manga fixture exposes catalog, page manifests, policies, and bounded resources", async (t) => {
  const dataRoot = await temporaryDirectory(t, "mgread-manga-fixture-");
  await new PluginInstaller(dataRoot).installProject(mangaFixtureRoot);
  const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=", "base64");
  const calls = [];
  const manager = new PluginManager(dataRoot, { http: { async fetch(input, init) {
    calls.push({ input, init });
    return new Response(png, { headers: { "content-type": "image/png" } });
  } } });
  await manager.initialize();
  const signal = new AbortController().signal;
  const deadline = String(Date.now() + 5_000);
  const search = await manager.search("org.mgread.runtime.manga-fixture", { query: "固定", cursor: null, pageSize: 20 }, signal, deadline);
  assert.equal(search.items[0].contentKind, "manga");
  const detail = await manager.getDetail("org.mgread.runtime.manga-fixture", { id: "manga:fixture-book" }, signal, deadline);
  assert.equal(detail.contentKind, "manga");
  const chapters = await manager.getChapters("org.mgread.runtime.manga-fixture", { id: detail.id }, signal, deadline);
  assert.equal(chapters.items.length, 2);
  const first = await manager.getContent("org.mgread.runtime.manga-fixture", { id: detail.id, chapterId: chapters.items[0].id }, signal, deadline);
  const second = await manager.getContent("org.mgread.runtime.manga-fixture", { id: detail.id, chapterId: chapters.items[1].id }, signal, deadline);
  assert.equal(first.contentKind, "manga");
  assert.equal(first.pages.length, 2);
  assert.equal(first.pages[0].resourcePolicy, "sessionOnly");
  assert.equal(first.pages[0].expiresAt, null);
  assert.equal(second.pages[0].resourcePolicy, "durable");
  assert.equal(new URL(second.pages[0].url).host, "example.invalid");
  assert.match(new URL(second.pages[0].url).pathname, /\/manga\/fixture-book\/manga:fixture-book:chapter-2\/page-0\.png$/u);
  const token = new URL(first.pages[0].url).pathname.split("/").at(-1);
  const resource = await manager.openSourceResource(token, {}, signal);
  assert.equal(resource?.response.headers.get("content-type"), "image/png");
  const body = new Uint8Array(await resource.response.arrayBuffer());
  assert.equal(body.length > 32, true);
  assert.deepEqual([...body.subarray(0, 8)], [137, 80, 78, 71, 13, 10, 26, 10]);
  assert.equal(calls[0].input, `https://fixture.invalid/${chapters.items[0].id}/page-0.png`);
  assert.deepEqual(calls[0].init.headers, { Accept: "image/png", Referer: "https://example.invalid/manga/fixture-book" });
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
    0,
  );
  assert.equal(
    (await manager.search(
      "org.mgread.runtime.fixture",
      { query: "回滚后懒加载", cursor: null, pageSize: 20 },
      new AbortController().signal,
      String(Date.now() + 5_000),
    )).items[0].title,
    "标准插件：回滚后懒加载",
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

test("a persisted current source is quarantined only when lazy activation finds damage", async (t) => {
  const dataRoot = await temporaryDirectory(t, "mgread-plugin-lazy-quarantine-");
  await new PluginInstaller(dataRoot).installProject(fixtureRoot);
  const pluginRoot = join(dataRoot, "plugins", "org.mgread.runtime.fixture");
  await writeFile(join(pluginRoot, "current"), "1.0.0\n");
  await rm(join(pluginRoot, "pending"));
  const entry = join(pluginRoot, "versions", "1.0.0", "dist", "index.mjs");
  await chmod(entry, 0o644);
  await writeFile(entry, "export const broken = ;\n");

  const events = [];
  const manager = new PluginManager(dataRoot, {
    events: (event) => events.push(event),
  });
  t.after(() => manager.close());
  await manager.initialize();
  assert.equal((await manager.listInstalled())[0].status, "active");
  assert.equal(events.filter((event) => event.code === "plugin_load_started").length, 0);
  assert.deepEqual(await manager.consumeStartupRecovery(), { quarantinedCount: 0 });
  const packagePath = join(pluginRoot, "versions", "1.0.0", "package.json");
  await chmod(packagePath, 0o644);
  await writeFile(
    packagePath,
    "{ damaged after startup\n",
  );

  await assert.rejects(
    manager.search(
      "org.mgread.runtime.fixture",
      { query: "损坏", cursor: null, pageSize: 20 },
      new AbortController().signal,
      String(Date.now() + 5_000),
    ),
    (error) => error?.code === "plugin_load_failed",
  );
  const quarantined = (await manager.listInstalled())[0];
  assert.equal(quarantined.status, "quarantined");
  assert.equal(quarantined.enabled, false);
  assert.equal(
    (await readFile(join(pluginRoot, "quarantined"), "utf8")).trim(),
    "1.0.0",
  );
  assert.deepEqual(await manager.consumeStartupRecovery(), { quarantinedCount: 0 });
  assert.equal(events.filter((event) => event.code === "plugin_quarantined").length, 1);
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
      String(Date.now() + 10),
    ),
    (error) => error?.code === "timeout",
  );
  await waitFor(
    () => events.filter((event) => event.code === "plugin_invocation_failed").length === 2,
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

test("browser.session.v1 is bounded, host-owned, and preserves stable failures", async (t) => {
  const dataRoot = await temporaryDirectory(t, "mgread-plugin-browser-session-");
  await new PluginInstaller(dataRoot).installProject(fixtureRoot);
  const calls = [];
  const manager = new PluginManager(dataRoot, {
    browserSession: {
      async request(request) {
        calls.push(request);
        return {
          version: 1,
          status: 200,
          finalUrl: request.url,
          headers: { "content-type": "text/html" },
          body: "fixture-browser-body",
        };
      },
    },
  });
  await manager.initialize();
  const result = await manager.search(
    "org.mgread.runtime.fixture",
    { query: "browser-session", cursor: null, pageSize: 20 },
    new AbortController().signal,
    String(Date.now() + 5_000),
  );
  assert.equal(result.items[0].title, "标准插件：browser-200");
  assert.equal(calls.length, 1);
  assert.equal(calls[0].pluginId, "org.mgread.runtime.fixture");
  assert.equal(calls[0].headers.cookie, undefined);
  assert.equal(calls[0].headers["user-agent"], undefined);
  assert.equal(calls[0].presentation, "hidden");
  assert.equal(calls[0].transport, "webview");
  assert.equal(calls[0].signal.aborted, false);

  await assert.rejects(
    manager.search("org.mgread.runtime.fixture", { query: "browser-cookie", cursor: null, pageSize: 20 }, new AbortController().signal, String(Date.now() + 5_000)),
    (error) => error?.code === "invalid_request",
  );

  const interaction = new PluginManager(dataRoot, { browserSession: { async request() { throw new PluginBrowserSessionError("interaction_required"); } } });
  await interaction.initialize();
  await assert.rejects(
    interaction.search("org.mgread.runtime.fixture", { query: "browser-session", cursor: null, pageSize: 20 }, new AbortController().signal, String(Date.now() + 5_000)),
    (error) => error?.code === "interaction_required",
  );

  const unsupported = new PluginManager(dataRoot);
  await unsupported.initialize();
  await assert.rejects(
    unsupported.search(
      "org.mgread.runtime.fixture",
      { query: "browser-session", cursor: null, pageSize: 20 },
      new AbortController().signal,
      String(Date.now() + 5_000),
    ),
    (error) => error?.code === "unsupported",
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

  await assert.rejects(
    manager.getDetail(
      "org.example.delayed",
      { id: "media-resolution" },
      new AbortController().signal,
      String(Date.now() + 5_000),
    ),
    (error) => error?.code === "source_media_resolution_failed",
  );

  await assert.rejects(
    manager.getDetail(
      "org.example.delayed",
      { id: "access-blocked" },
      new AbortController().signal,
      String(Date.now() + 5_000),
    ),
    (error) =>
      error?.code === "source_access_blocked" &&
      error?.detail === "访问异常，请稍后再试。\n注释：当前 IP 可能异常，请更换 IP 后重试。",
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

test("media catalogs preserve neutral groups and require proxy playback metadata", () => {
  const episode = (id, order) => ({
    id, title: `Episode ${order + 1}`, order, url: null, volumeTitle: null,
    wordCount: null, updatedAt: null, isLocked: false, attributes: [],
  });
  const catalog = validateChaptersResult("org.example.video", "Fixture video", {
    items: [episode("episode:a", 0), episode("episode:b", 1)],
    groups: [{ id: "group:source-a", title: "Source A", order: 0, episodes: [episode("episode:a", 0), episode("episode:b", 1)] }],
  });
  assert.equal(catalog.groups[0].title, "Source A");
  assert.equal(catalog.groups[0].episodes[1].id, "episode:b");
  const content = validateContentResult("org.example.video", "Fixture video", {
    chapterId: "episode:a", contentKind: "video", title: null, updatedAt: null,
    text: null, pages: [], media: {
      url: "http://127.0.0.1/v1/source-resource/abcdefghijklmnop", resourceType: "hls",
      resourcePolicy: "refreshable", expiresAt: "2026-08-30T00:05:00Z",
      mimeType: "application/vnd.apple.mpegurl", headers: { Referer: "https://example.test/" },
    },
  });
  assert.equal(content.media.resourceType, "hls");
  assert.throws(() => validateContentResult("org.example.video", "Fixture video", {
    chapterId: "episode:a", contentKind: "video", title: null, updatedAt: null,
    text: null, pages: [], media: {
      url: "https://upstream.example/media.m3u8", resourceType: "hls",
      resourcePolicy: "refreshable", expiresAt: null, mimeType: null, headers: {},
    },
  }), PluginContentValidationError);
});

test("source proxy requests recover from their self-contained token without Manager memory", async (t) => {
  const dataRoot = await temporaryDirectory(t, "mgread-media-proxy-");
  const calls = [];
  const issuingManager = new PluginManager(dataRoot);
  issuingManager.setResourceOrigin("http://127.0.0.1:9000");
  const url = issuingManager.createResourceUrl("org.example.media", {
    kind: "hls",
    url: "https://media.example/playlist.m3u8",
    headers: { Referer: "https://source.example/watch" },
  });
  await issuingManager.close();
  const token = new URL(url).pathname.split("/").at(-1);
  assert.deepEqual(JSON.parse(Buffer.from(token, "base64url").toString("utf8")), {
    pluginId: "org.example.media",
    request: {
      kind: "hls",
      url: "https://media.example/playlist.m3u8",
      headers: { Referer: "https://source.example/watch" },
    },
    version: 1,
  });

  const recoveringManager = new PluginManager(dataRoot, {
    http: {
      async fetch(input, init) {
        calls.push({ input: String(input), init });
        return new Response("#EXTM3U\nsegment.ts\n", {
          headers: { "content-type": "application/vnd.apple.mpegurl" },
        });
      },
    },
  });
  recoveringManager.setResourceOrigin("http://127.0.0.1:9000");
  const resource = await recoveringManager.openSourceResource(token, { range: "bytes=0-1023" }, new AbortController().signal);

  assert.equal(resource?.response.status, 200);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].input, "https://media.example/playlist.m3u8");
  assert.deepEqual(calls[0].init.headers, {
    Referer: "https://source.example/watch",
    range: "bytes=0-1023",
  });
  await recoveringManager.close();
});

test("source proxy rejects the removed plugin-owned resource descriptor shape", async (t) => {
  const dataRoot = await temporaryDirectory(t, "mgread-removed-resource-shape-");
  let fetches = 0;
  const manager = new PluginManager(dataRoot, { http: { async fetch() {
    fetches += 1;
    return new Response("unexpected");
  } } });
  const url = manager.createResourceUrl("org.example.legacy", {
    kind: "image",
    url: "https://images.example/legacy.jpg",
    referer: "https://source.example/",
  });
  const token = new URL(url).pathname.split("/").at(-1);

  assert.equal(await manager.openSourceResource(token, {}, new AbortController().signal), undefined);
  assert.equal(fetches, 0);
});
