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
  return {
    id,
    title: formatFixtureTitle(prefix, query),
    contentKind: "novel",
    author: context.plugin.id,
    url: `https://example.invalid/books/${encodeURIComponent(id)}`,
    coverUrl: query === "proxy-resource" ? context.resource.proxy({ kind: "fixture" }) : null,
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

export async function resource(request) {
  if (request.kind !== "fixture") return { status: 404, body: "" };
  return { status: 206, headers: { "content-type": "image/test" }, body: new Uint8Array([77, 71, 82, 69, 65, 68]) };
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
    nextCursor: null,
    totalCount: 1,
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
