/**
 * Runtime Debug inspector listener contract tests.
 *
 * Responsibilities:
 * - verify safe source projections, cover probes and transient log paging;
 * - prove Debug-gated Runtime startup creates no persistent diagnostics directory.
 *
 * Boundaries:
 * - uses temporary data roots and listeners only;
 * - never relies on a running MgRead application or external network service.
 *
 * TODO:
 * - None.
 */
import assert from "node:assert/strict";
import { access, mkdtemp, rm } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { RuntimeDebugHttpServer, RuntimeDebugLogBuffer } from "../dist/debug-http.js";
import { DesktopRuntime } from "../dist/desktop-runtime.js";

async function startImageServer() {
  const server = createServer((_request, response) => {
    response.writeHead(200, { "Content-Length": "4", "Content-Type": "image/png" });
    response.end(Buffer.from([137, 80, 78, 71]));
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.once("listening", resolve);
    server.listen({ host: "127.0.0.1", port: 0 });
  });
  const address = server.address();
  assert.ok(address && typeof address !== "string");
  return { server, url: `http://127.0.0.1:${address.port}/cover` };
}

test("Debug inspector is transient, isolates control routes, and redacts cover tokens", async (t) => {
  const image = await startImageServer();
  const logs = new RuntimeDebugLogBuffer();
  logs.append({
    level: "info",
    message: "request token=secret-token-123456 https://example.com/book?q=private",
    source: "plugin",
  });
  const inspector = new RuntimeDebugHttpServer({
    chapters: async () => ({ items: [{ attributes: [], id: "chapter:1", isLocked: false, order: 1, title: "第一章", updatedAt: null, url: "https://example.com/chapter/secret-token-123456", volumeTitle: null, wordCount: null }] }),
    content: async () => ({ chapterId: "chapter:1", contentKind: "novel", pages: [], text: "正文测试", title: "第一章", updatedAt: null }),
    detail: async () => ({ access: "free", aliases: ["测试别名"], attributes: [], author: "作者", catalogUrl: "https://example.com/catalog/secret-token-123456", categories: [], chapterCount: 1, contentKind: "novel", coverUrl: image.url, description: "详情", id: "novel:1", language: null, latestChapter: null, publishedAt: null, status: "ongoing", tags: [], title: "测试书", updatedAt: null, url: "https://example.com/book/secret-token-123456", wordCount: 1 }),
    discover: async () => ({
      document: {
        components: [{ children: [{ content: { attributes: [{ key: "origin", label: "来源", value: "测试书源" }], author: "发现作者", categories: ["都市"], chapterCount: 128, coverUrl: image.url, description: "发现书简介", id: "novel:discover", latestChapter: { id: "chapter:128", title: "终章", updatedAt: "2026-08-25", url: "https://example.com/chapter/secret-token-123456" }, tags: ["推荐"], title: "发现书", url: "https://example.com/book/secret-token-123456", wordCount: 456789 }, kind: "content" }], kind: "section", title: "推荐" }],
        kind: "document",
      },
      kind: "document",
    }),
    logs: (after, limit) => logs.page(after, limit),
    plugins: async () => [],
    search: async () => ({
      items: [{ author: "作者", coverUrl: image.url + "/secret-token-123456", id: "novel:1", title: "测试书" }],
      nextCursor: null,
      totalCount: 1,
    }),
    status: async () => ({ nodeVersion: "24.16.0", runtimeVersion: "test", status: "ready" }),
  });
  t.after(async () => {
    await inspector.dispose();
    await new Promise((resolve) => image.server.close(resolve));
  });

  assert.equal(inspector.status().enabled, false);
  const enabled = await inspector.setEnabled(true);
  assert.equal(enabled.enabled, true);
  const base = enabled.endpoints.find((value) => value.startsWith("http://127.0.0.1:"));
  assert.ok(base);

  const page = await fetch(base);
  assert.equal(page.status, 200);
  assert.match(await page.text(), /__debug\/app\.js/);
  assert.match(await (await fetch(new URL("/__debug/app.css", base))).text(), /tree-node/);
  assert.match(await (await fetch(new URL("/__debug/app.js", base))).text(), /createDiscoverNode/);
  assert.equal((await fetch(new URL("/v1/rpc", base))).status, 404);

  const liveLogs = await (await fetch(new URL("/__debug/api/logs?after=0&limit=20", base))).json();
  assert.equal(liveLogs.items.length, 1);
  assert.match(liveLogs.items[0].message, /token: \[redacted\]/);
  assert.match(liveLogs.items[0].message, /\?\[redacted\]/);
  assert.doesNotMatch(JSON.stringify(liveLogs), /secret-token-123456|q=private/);

  const search = await fetch(new URL("/__debug/api/search?pluginId=org.example.test&q=test&pageSize=1", base));
  assert.equal(search.status, 200);
  const result = await search.json();
  const cover = result.result.items[0].cover;
  assert.equal(cover.type, "ordinary-url");
  assert.match(cover.displayUrl, /sec…456/);
  assert.doesNotMatch(JSON.stringify(result), /secret-token-123456/);

  const discover = await fetch(new URL("/__debug/api/discover?pluginId=org.example.test&pageSize=1", base));
  assert.equal(discover.status, 200);
  const discoveryResult = await discover.json();
  assert.equal(discoveryResult.result.document.components[0].kind, "section");
  assert.equal(discoveryResult.result.document.components[0].children[0].content.cover.type, "ordinary-url");
  assert.equal(discoveryResult.result.document.components[0].children[0].content.chapterCount, 128);
  assert.equal(discoveryResult.result.document.components[0].children[0].content.attributes[0].label, "来源");
  assert.match(discoveryResult.result.document.components[0].children[0].content.url, /sec…456/);
  assert.doesNotMatch(JSON.stringify(discoveryResult), /secret-token-123456/);

  const detail = await (await fetch(new URL("/__debug/api/detail?pluginId=org.example.test&id=novel%3A1", base))).json();
  assert.equal(detail.result.aliases[0], "测试别名");
  assert.match(detail.result.catalogUrl, /sec…456/);
  const chapters = await (await fetch(new URL("/__debug/api/chapters?pluginId=org.example.test&id=novel%3A1", base))).json();
  assert.equal(chapters.result.items[0].title, "第一章");
  assert.match(chapters.result.items[0].url, /sec…456/);
  const content = await (await fetch(new URL("/__debug/api/content?pluginId=org.example.test&id=novel%3A1&chapterId=chapter%3A1", base))).json();
  assert.equal(content.result.text, "正文测试");

  const probe = await fetch(new URL(`/__debug/api/resource-probe?probeId=${cover.probeId}`, base));
  assert.equal(probe.status, 200);
  assert.equal(probe.headers.get("content-type"), "image/png");
  assert.deepEqual([...new Uint8Array(await probe.arrayBuffer())], [137, 80, 78, 71]);

  const disabled = await inspector.setEnabled(false);
  assert.deepEqual(disabled, { enabled: false, endpoints: [], startedAt: null });
});

test("Runtime rejects Debug listener control without the platform Debug build gate", async (t) => {
  const dataRoot = await mkdtemp(join(tmpdir(), "mgread-no-runtime-events-"));
  const runtime = new DesktopRuntime({ dataRoot });
  t.after(async () => {
    await runtime.stop();
    await rm(dataRoot, { force: true, recursive: true });
  });
  await runtime.start();

  const result = await runtime.invokeEmbedded("runtime.debugHttp.setEnabled.v1", { enabled: true });
  assert.equal(result.ok, false);
  assert.equal(result.error.code, "method_not_found");
  await assert.rejects(access(join(dataRoot, "diagnostics")), (error) => error?.code === "ENOENT");
});

test("Debug log buffer is bounded, redacted, pageable, and clearable", () => {
  const logs = new RuntimeDebugLogBuffer();
  for (let index = 1; index <= 1_005; index += 1) {
    logs.append({
      level: "info",
      message: `entry ${index} password=private`,
      source: "runtime",
    });
  }

  const first = logs.page(0, 200);
  const second = logs.page(first.nextSequence, 200);
  assert.equal(first.items.length, 200);
  assert.equal(first.items[0].sequence, 6);
  assert.equal(first.items.at(-1).sequence, 205);
  assert.equal(second.items[0].sequence, 206);
  assert.equal(second.items.at(-1).sequence, 405);
  assert.equal(first.droppedCount, 5);
  assert.doesNotMatch(JSON.stringify([first, second]), /private/);

  logs.clear();
  assert.deepEqual(logs.page(0, 200), { droppedCount: 0, items: [], nextSequence: 1_005 });
});
