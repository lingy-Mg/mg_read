import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import { PluginManager } from "../dist/index.js";

const npmCli = fileURLToPath(new URL(
  process.platform === "darwin"
    ? "../tools/node-v24.16.0-darwin-arm64/lib/node_modules/npm/bin/npm-cli.js"
    : "../tools/node-v24.16.0-win-x64/node_modules/npm/bin/npm-cli.js",
  import.meta.url,
));

async function temporaryDirectory(t, prefix) {
  const root = await mkdtemp(join(tmpdir(), prefix));
  t.after(() => rm(root, { force: true, recursive: true }));
  return root;
}

async function waitFor(predicate, timeoutMs = 12_000) {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error("Timed out waiting for hot reload.");
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
}

function source(prefix, delayMs = 0) {
  return `
export function activate() {}
const summary = (query) => ({
  id: "live:" + query, title: ${JSON.stringify(prefix)} + "：" + query,
  contentKind: "novel", author: null, url: null, coverUrl: null,
  description: null, language: null, status: "unknown", access: "unknown",
  wordCount: null, chapterCount: 0, publishedAt: null, updatedAt: null,
  latestChapter: null, categories: [], tags: [], attributes: [],
});
export function discover() { return { kind: "document", document: { components: [] } }; }
export async function search(request) {
  ${delayMs > 0 ? `await new Promise((resolve) => setTimeout(resolve, ${delayMs}));` : ""}
  return { items: [summary(request.query)], nextCursor: null, totalCount: 1 };
}
export function getDetail(request) { return { ...summary(request.id), id: request.id, aliases: [], catalogUrl: null }; }
export function getChapters() { return { items: [], nextCursor: null, totalCount: 0 }; }
export function getContent(request) { return { contentKind: "novel", chapterId: request.chapterId, title: null, updatedAt: null, text: "text", pages: [] }; }
`;
}

async function createProject(projectRoot, pluginId, prefix) {
  await Promise.all([
    mkdir(join(projectRoot, "src"), { recursive: true }),
    mkdir(join(projectRoot, "dist"), { recursive: true }),
    mkdir(join(projectRoot, "tools"), { recursive: true }),
  ]);
  const packageJson = {
    name: `@mgread-plugin/${pluginId.split(".").at(-1)}`,
    version: "0.1.0",
    type: "module",
    main: "dist/index.mjs",
    scripts: { build: "node build.mjs" },
    engines: { node: ">=24 <25" },
    mgread: {
      schemaVersion: 1,
      id: pluginId,
      displayName: prefix,
      pluginApi: 1,
      contentKinds: ["novel"],
    },
  };
  await Promise.all([
    writeFile(join(projectRoot, "package.json"), `${JSON.stringify(packageJson, null, 2)}\n`),
    writeFile(
      join(projectRoot, "build.mjs"),
      "import { copyFile } from 'node:fs/promises';\n" +
        "await copyFile(new URL('./src/index.mjs', import.meta.url), new URL('./dist/index.mjs', import.meta.url));\n",
    ),
    writeFile(join(projectRoot, "src", "index.mjs"), source(prefix)),
    writeFile(join(projectRoot, "dist", "index.mjs"), source(prefix)),
    writeFile(
      join(projectRoot, "tools", "mgread.mjs"),
      "export function buildPluginArtifactForProject(_root, { versionOverride }) { return { bytes: new TextEncoder().encode(versionOverride), fileName: 'fixture.mgplugin.js', format: 'singleFile' }; }\n" +
        "export function buildPluginArtifact(options) { return buildPluginArtifactForProject('.', options); }\n",
    ),
  ]);
}

async function search(manager, pluginId) {
  return manager.search(
    pluginId,
    { query: "测试", cursor: null, pageSize: 20 },
    new AbortController().signal,
    String(Date.now() + 10_000),
  );
}

test(
  "development builds hot swap generations and retain the old version on failure",
  { skip: process.platform !== "win32" && process.platform !== "darwin" },
  async (t) => {
  const root = await temporaryDirectory(t, "mgread-development-hot-reload-");
  const dataRoot = join(root, "runtime-data");
  const developmentRoot = join(root, "sources");
  const firstRoot = join(developmentRoot, "first-source");
  await createProject(firstRoot, "org.example.watched", "第一版");
  const events = [];
  const manager = new PluginManager(dataRoot, {
    developmentPluginRoot: developmentRoot,
    developmentNpmCli: npmCli,
    events: (event) => events.push(event),
  });
  t.after(() => manager.close());
  await manager.initialize();
  assert.equal((await search(manager, "org.example.watched")).items[0].title, "第一版：测试");
  const initialArtifact = (await manager.listExportableArtifacts())[0];
  const repeatedArtifact = (await manager.listExportableArtifacts())[0];
  assert.equal(initialArtifact.provenance, "development");
  assert.equal(repeatedArtifact.version, initialArtifact.version);
  assert.equal(repeatedArtifact.developmentFingerprint, initialArtifact.developmentFingerprint);
  assert.equal(repeatedArtifact.developmentRevision, initialArtifact.developmentRevision);

  const reloadStartedAt = performance.now();
  await writeFile(join(firstRoot, "src", "index.mjs"), source("第二版", 3_000));
  await waitFor(() => events.some((event) => event.code === "development_plugin_updated"));
  console.log(JSON.stringify({ developmentHotReloadMs: Math.round(performance.now() - reloadStartedAt) }));
  assert.equal((await search(manager, "org.example.watched")).items[0].title, "第二版：测试");
  const updatedArtifact = (await manager.listExportableArtifacts())[0];
  assert.notEqual(updatedArtifact.developmentFingerprint, initialArtifact.developmentFingerprint);
  assert.ok(updatedArtifact.developmentRevision > initialArtifact.developmentRevision);

  const staleRequest = search(manager, "org.example.watched");
  await writeFile(join(firstRoot, "src", "index.mjs"), source("第三版"));
  await waitFor(
    () => events.filter((event) => event.code === "development_plugin_updated").length === 2,
  );
  await assert.rejects(staleRequest, (error) => error?.code === "plugin_execution_failed");
  assert.equal((await search(manager, "org.example.watched")).items[0].title, "第三版：测试");

  const packagePath = join(firstRoot, "package.json");
  const packageJson = JSON.parse(await readFile(packagePath, "utf8"));
  packageJson.scripts.build = "node -e \"console.log('build stdout'); console.error('build stderr'); process.exit(7)\"";
  await writeFile(packagePath, `${JSON.stringify(packageJson, null, 2)}\n`);
  await waitFor(() => events.some((event) => event.code === "development_plugin_build_failed"));
  const buildFailure = events.find((event) => event.code === "development_plugin_build_failed");
  assert.equal(buildFailure.pluginId, "org.example.watched");
  assert.equal(buildFailure.pluginName, "第一版");
  assert.match(buildFailure.buildOutput, /build stdout/);
  assert.match(buildFailure.buildOutput, /build stderr/);
  assert.match(buildFailure.buildOutput, /code=7/);
  assert.equal((await search(manager, "org.example.watched")).items[0].title, "第三版：测试");

  const secondRoot = join(developmentRoot, "second-source");
  await createProject(secondRoot, "org.example.added", "新增");
  await waitFor(() => events.some(
    (event) => event.code === "development_plugin_added" && event.pluginId === "org.example.added",
  ));
  assert.deepEqual(
    (await manager.listInstalled()).map((plugin) => plugin.id).sort(),
    ["org.example.added", "org.example.watched"],
  );
  await rm(secondRoot, { force: true, recursive: true });
  await waitFor(() => events.some(
    (event) => event.code === "development_plugin_removed" && event.pluginId === "org.example.added",
  ));
  assert.deepEqual(
    (await manager.listInstalled()).map((plugin) => plugin.id),
    ["org.example.watched"],
  );
  assert.equal(JSON.stringify(events).includes(root), false);
  },
);

test(
  "cold start rebuilds only a development project edited while the App was closed",
  { skip: process.platform !== "win32" && process.platform !== "darwin" },
  async (t) => {
    const root = await temporaryDirectory(t, "mgread-development-cold-catch-up-");
    const dataRoot = join(root, "runtime-data");
    const developmentRoot = join(root, "sources");
    const projectRoot = join(developmentRoot, "cold-source");
    await createProject(projectRoot, "org.example.cold-source", "第一版");

    const first = new PluginManager(dataRoot, {
      developmentPluginRoot: developmentRoot,
      developmentNpmCli: npmCli,
    });
    const firstOffer = (await first.listPluginTransferOffers())[0];
    assert.equal((await search(first, "org.example.cold-source")).items[0].title, "第一版：测试");
    await first.close();

    await writeFile(join(projectRoot, "src", "index.mjs"), source("停机修改"));
    const restarted = new PluginManager(dataRoot, {
      developmentPluginRoot: developmentRoot,
      developmentNpmCli: npmCli,
    });
    t.after(() => restarted.close());
    const restartedOffer = (await restarted.listPluginTransferOffers())[0];

    assert.equal((await search(restarted, "org.example.cold-source")).items[0].title, "停机修改：测试");
    assert.notEqual(restartedOffer.developmentFingerprint, firstOffer.developmentFingerprint);
    assert.ok(restartedOffer.developmentRevision > firstOffer.developmentRevision);
  },
);
