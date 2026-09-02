import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";

import { formatFixtureTitle } from "local-helper";

let context;
let prefix;

export async function activate(nextContext) {
  context = nextContext;
  const rules = JSON.parse(
    await readFile(new URL("../assets/rules.json", import.meta.url), "utf8"),
  );
  prefix = rules.prefix;
  await writeFile(
    join(context.dataDir, "activated.json"),
    JSON.stringify({ pluginApi: context.app.pluginApi }),
  );
  context.log.info("fixture_activated");
}

function contentSummary(query) {
  const id = `fixture:${query}`;
  const proxyResourceUrl = query.startsWith("proxy-resource:") ? query.slice("proxy-resource:".length) : null;
  return {
    id,
    title: formatFixtureTitle(prefix, query),
    contentKind: "novel",
    author: context.plugin.id,
    url: `https://example.invalid/books/${encodeURIComponent(id)}`,
    coverUrl: proxyResourceUrl === null ? null : context.resource.proxy({ kind: "image", url: proxyResourceUrl, headers: { Accept: "image/test" } }),
    description: "标准插件富字段测试内容。",
    language: "zh-CN",
    status: "ongoing",
    access: "free",
    wordCount: 123456,
    chapterCount: 1,
    publishedAt: null,
    updatedAt: "2026-08-15T00:00:00Z",
    latestChapter: {
      id: `${id}:chapter-1`,
      title: "第一章",
      url: null,
      updatedAt: "2026-08-15T00:00:00Z",
    },
    categories: ["测试"],
    tags: [],
    attributes: [],
  };
}

export async function discover(_request) {
  return {
    kind: "document",
    document: { components: [
      { type: "tabs", id: "tabs", tabs: [{ id: "recommend", label: "推荐", target: "recommend" }], selectedTabId: "recommend" },
      {
        type: "section",
        id: "featured-section",
        title: "编辑精选",
        subtitle: null,
        children: [{
          type: "contentCollection",
          id: "featured",
          layout: "featured",
          continuation: null,
          items: [
          {
            content: contentSummary("发现"),
            rank: null,
            metric: null,
            recommendation: "离线固定推荐",
          },
          ],
        }],
      },
      {
        type: "section",
        id: "categories-section",
        title: "分类",
        subtitle: null,
        children: [{
          type: "categoryCollection",
          id: "categories",
          layout: "grid",
          categories: [
          {
            id: "test",
            title: "测试",
            target: "category:test",
            count: 1,
            url: null,
          },
          ],
        }],
      },
    ]},
  };
}

export async function search(request) {
  if (request.query === "browser-cookie") {
    await context.browser.sessionV1.request({ version: 1, sessionKey: "fixture", url: "https://example.invalid/protected", method: "GET", headers: { cookie: "forbidden" }, body: null, interaction: "silent", presentation: "hidden", transport: "http", timeoutMs: 5_000, maxResponseBytes: 4_096 });
  }
  if (request.query === "browser-session") {
    const response = await context.browser.sessionV1.request({
      version: 1,
      sessionKey: "fixture",
      url: "https://example.invalid/protected",
      method: "GET",
      headers: { accept: "text/html" },
      body: null,
      interaction: "silent",
      presentation: "hidden",
      transport: "webview",
      timeoutMs: 5_000,
      maxResponseBytes: 4_096,
    });
    return {
      items: [contentSummary(`browser-${response.status}`)],
      nextCursor: null,
      totalCount: 1,
    };
  }
  return {
    items: [contentSummary(request.query)],
    nextCursor: null,
    totalCount: 1,
  };
}

export async function getDetail(request) {
  return {
    ...contentSummary(request.id),
    id: request.id,
    aliases: [],
    catalogUrl: null,
  };
}

export async function getChapters(request) {
  return {
    items: [
      {
        id: `${request.id}:chapter-1`,
        title: "第一章",
        order: 0,
        url: null,
        volumeTitle: null,
        wordCount: 12,
        updatedAt: "2026-08-15T00:00:00Z",
        isLocked: false,
        attributes: [],
      },
    ],
  };
}

export async function getContent(request) {
  return {
    contentKind: "novel",
    chapterId: request.chapterId,
    title: "第一章",
    updatedAt: "2026-08-15T00:00:00Z",
    text: "标准插件正文。",
    pages: [],
  };
}
