/**
 * Android integration fixture for the published Source API.
 *
 * It uses only the standard Node loader and a host-owned WebView. The host
 * test supplies no network dependency, so backend differences stay visible.
 */
import { createHash } from "node:crypto";

let context;

export function activate(nextContext) {
  context = nextContext;
  createHash("sha256").update(context.plugin.id).digest("hex");
}

function summary(title) {
  return {
    id: "fixture:one",
    title,
    contentKind: "novel",
    author: "MgRead",
    url: "https://example.invalid/android-runtime-fixture",
    coverUrl: null,
    description: "Android Runtime fixture",
    language: "zh-CN",
    status: "ongoing",
    access: "free",
    wordCount: 4,
    chapterCount: 1,
    publishedAt: null,
    updatedAt: null,
    latestChapter: null,
    categories: [],
    tags: [],
    attributes: [],
  };
}

export function discover() {
  return { kind: "document", document: { components: [] } };
}

export async function search(request) {
  let title = `fixture:${request.query}`;
  if (request.query === "slow") {
    await new Promise((resolve) => setTimeout(resolve, 10_000));
  }
  if (request.query === "android-webview") {
    const page = await context.webview.open({ visible: false, timeoutMs: 10_000 });
    try {
      const result = await page.executeJavaScript("return 1 + 1;", { timeoutMs: 10_000 });
      title = `webview:${result}`;
    } finally {
      await page.close();
    }
  }
  return { items: [summary(title)], nextCursor: null, totalCount: 1 };
}

export function getDetail(request) {
  return { ...summary("fixture:detail"), id: request.id, aliases: [], catalogUrl: null };
}

export function getChapters() {
  return {
    items: [{
      id: "chapter:one", title: "Fixture chapter", order: 0,
      url: null, volumeTitle: null, wordCount: 4, updatedAt: null,
      isLocked: false, attributes: [],
    }],
  };
}

export function getContent() {
  return { contentKind: "novel", chapterId: "chapter:one", title: "Fixture chapter", updatedAt: null, text: "Fixture chapter body.", pages: [] };
}
