import { createRequire as __mgreadCreateRequire } from 'node:module'; const require = __mgreadCreateRequire(import.meta.url);

// src/catalog.ts
var ElkopartsCatalog = class {
  constructor(read, pages, parse) {
    this.read = read;
    this.pages = pages;
    this.parse = parse;
  }
  read;
  pages;
  parse;
  #cache = /* @__PURE__ */ new Map();
  async load(request, firstUrl) {
    if (request.refresh) this.#cache.delete(request.id);
    let pending = this.#cache.get(request.id);
    if (!pending) {
      pending = this.read(firstUrl).then((firstHtml) => {
        const pages = this.pages(firstHtml, firstUrl);
        if (pages.length > 1024) throw new Error("Catalog exceeds the supported page bound.");
        return { firstHtml, pages, expires: Date.now() + 15 * 6e4 };
      }).catch((error) => {
        if (this.#cache.get(request.id) === pending) this.#cache.delete(request.id);
        throw error;
      });
      this.#cache.set(request.id, pending);
      while (this.#cache.size > 4) this.#cache.delete(this.#cache.keys().next().value);
    }
    const catalog = await pending;
    if (catalog.expires < Date.now()) {
      this.#cache.delete(request.id);
      return this.load(request, firstUrl);
    }
    const width = Math.max(1, Math.ceil(catalog.pages.length / 128));
    const starts = Array.from({ length: Math.ceil(catalog.pages.length / width) }, (_, index) => index * width);
    const groupId = (start2) => `${request.id}:catalog:${Buffer.from(catalog.pages[start2].pathname).toString("base64url")}`;
    const read = async (start2, count) => {
      const pages = catalog.pages.slice(start2, start2 + count);
      const chunks = new Array(pages.length);
      let next = 0;
      const worker = async () => {
        while (next < pages.length) {
          const index = next++, url = pages[index];
          const html = start2 + index === 0 ? catalog.firstHtml : await this.read(url);
          chunks[index] = this.parse(html, url, request.id);
        }
      };
      await Promise.all(Array.from({ length: Math.min(8, pages.length) }, worker));
      const seen = /* @__PURE__ */ new Set();
      const items2 = chunks.flat().filter((item) => {
        if (seen.has(item.id)) return false;
        seen.add(item.id);
        return true;
      }).map((item, order) => ({ ...item, order }));
      if (items2.length > 5e3) throw new Error("Catalog requires deferred chapter groups.");
      return items2;
    };
    if (request.supportsDeferredGroups !== true && request.groupId === void 0) return { items: await read(0, catalog.pages.length) };
    const start = request.groupId === void 0 ? 0 : starts.find((value) => groupId(value) === request.groupId);
    if (start === void 0) throw new Error("Requested catalog group is unavailable.");
    const items = await read(start, width);
    const groups = starts.map((value, order) => ({
      id: groupId(value),
      title: `目录第${value + 1}${width > 1 ? `–${Math.min(value + width, catalog.pages.length)}` : ""}页`,
      order,
      episodes: value === start ? items : [],
      ...value === start ? {} : { deferred: true }
    }));
    return { items, groups };
  }
};

// src/source.ts
var sourceOrigin = "http://www.elkoparts.net";
var categories = Object.freeze([
  { id: "1", title: "玄幻奇幻", icon: "fantasy" },
  { id: "2", title: "武侠仙侠", icon: "wuxia" },
  { id: "3", title: "都市言情", icon: "urban" },
  { id: "4", title: "历史军事", icon: "history" },
  { id: "5", title: "网游竞技", icon: "game" },
  { id: "6", title: "科幻灵异", icon: "scienceFiction" },
  { id: "7", title: "女生频道", icon: "romance" }
]);
var ElkopartsSource = class {
  #context;
  #catalog = new ElkopartsCatalog(
    (url) => this.#fetchHtml(url),
    catalogPageUrls,
    (html, url, id) => this.#parseChapterPage(html, url, decodeBookId(id))
  );
  constructor(context2) {
    this.#context = context2;
  }
  async discover(request) {
    const pageSize = boundedPageSize(request.pageSize);
    if (request.target === null) {
      if (request.cursor !== null || request.collectionId !== null) throw new Error("Initial discovery request is invalid.");
      const home = await this.#fetchHtml(new URL("/", sourceOrigin));
      const latest = this.#parseRowBooks(home, new URL("/", sourceOrigin)).slice(0, pageSize);
      return {
        kind: "document",
        document: {
          components: [
            {
              type: "section",
              id: "elkoparts-latest-section",
              title: "最近更新",
              subtitle: null,
              icon: "newRelease",
              children: [{
                type: "contentCollection",
                id: "elkoparts-latest",
                layout: "compact",
                items: latest.map(toDiscoveryItem),
                continuation: null
              }]
            },
            {
              type: "section",
              id: "elkoparts-categories-section",
              title: "小说分类",
              subtitle: null,
              icon: "category",
              children: [{
                type: "categoryCollection",
                id: "elkoparts-categories",
                layout: "chips",
                categories: categories.map((category2) => ({
                  id: `category-${category2.id}`,
                  title: category2.title,
                  target: `category:${category2.id}`,
                  count: null,
                  url: new URL(`/ksl/${category2.id}/1.html`, sourceOrigin).toString(),
                  icon: category2.icon
                }))
              }]
            }
          ]
        }
      };
    }
    const category = decodeCategory(request.target);
    const page = decodePageCursor(request.cursor);
    const collectionId = `elkoparts-category-${category.id}`;
    if (request.collectionId !== null && request.collectionId !== collectionId) {
      throw new Error("Discovery collection is invalid.");
    }
    const pageUrl = new URL(`/ksl/${category.id}/${page}.html`, sourceOrigin);
    const html = await this.#fetchHtml(pageUrl);
    const items = this.#parseCategoryBooks(html, pageUrl).slice(0, pageSize).map(toDiscoveryItem);
    const nextPage = findNextCategoryPage(html, category.id, page);
    const continuation = nextPage === null ? null : { target: request.target, cursor: String(nextPage) };
    if (request.collectionId !== null) {
      return { kind: "append", collectionId, items, continuation };
    }
    return {
      kind: "document",
      document: {
        components: [{
          type: "section",
          id: `${collectionId}-section`,
          title: category.title,
          subtitle: null,
          children: [{
            type: "contentCollection",
            id: collectionId,
            layout: "coverGrid",
            items,
            continuation
          }]
        }]
      }
    };
  }
  async search(request) {
    if (request.cursor !== null) throw new Error("Search cursor is not supported.");
    const query = request.query.trim();
    if (query.length === 0) return { items: [], nextCursor: null, totalCount: 0 };
    const url = new URL("/search.php", sourceOrigin);
    url.searchParams.set("keyWord", query);
    const html = await this.#fetchHtml(url);
    return {
      items: this.#parseRowBooks(html, url).slice(0, boundedPageSize(request.pageSize)),
      nextCursor: null,
      totalCount: null
    };
  }
  searchSuggestions(_request) {
    return { items: [], nextCursor: null };
  }
  async getDetail(request) {
    const key = decodeBookId(request.id);
    const url = bookUrl(key);
    const html = await this.#fetchHtml(url);
    const title = textFromMatch(html, /<div\s+class=["'][^"']*info[^"']*["'][^>]*>[\s\S]*?<h1[^>]*>([\s\S]*?)<\/h1>/iu);
    if (title === null) throw new Error("Source detail title is missing.");
    const infoLines = captures(html, /<p[^>]*>([\s\S]*?)<\/p>/giu).map((value) => compact(decodeHtml(stripTags(value))));
    const author = prefixedValue(infoLines, "作者：");
    const category = prefixedValue(infoLines, "类别：");
    const statusText = prefixedValue(infoLines, "状态：");
    const coverTag = firstCapture(html, /<div\s+class=["'][^"']*imgbox[^"']*["'][^>]*>[\s\S]*?(<img\b[^>]*>)/iu);
    const cover = this.#coverProxy(normalizeCoverUrl(coverTag === null ? void 0 : attribute(coverTag, "src"), url));
    const description = normalizeDescription(
      textFromMatch(html, /<div\s+class=["'][^"']*\bxdesc\b[^"']*["'][^>]*>([\s\S]*?)<\/div>/iu) ?? textFromMatch(html, /<div\s+class=["'][^"']*\bdesc\b[^"']*["'][^>]*>([\s\S]*?)<\/div>/iu)
    );
    const latestBlock = firstCapture(html, /<p[^>]*>\s*最新(?:章节)?[：:]([\s\S]*?)<\/p>/iu) ?? "";
    const latest = firstLink(latestBlock, /^https?:\/\/www\.elkoparts\.net\/kanshu\/\d+\/\d+\/\d+\.html$|^\/kanshu\/\d+\/\d+\/\d+\.html$/u);
    const latestUrl = normalizeSourceUrl(latest?.href, url);
    const latestTitle = latest?.title ?? null;
    const chapterCount = parseChapterCount(html);
    return {
      ...summary({
        key,
        title,
        author,
        category,
        coverUrl: cover,
        description,
        status: contentStatus(statusText),
        chapterCount,
        latestChapter: latestUrl === null || latestTitle === null ? null : { id: chapterIdFromUrl(latestUrl), title: latestTitle, url: latestUrl.toString(), updatedAt: null }
      }),
      aliases: [],
      catalogUrl: url.toString()
    };
  }
  async getChapters(request) {
    return this.#catalog.load(request, bookUrl(decodeBookId(request.id)));
  }
  async getContent(request) {
    const book = decodeBookId(request.id);
    const chapter = decodeChapterId(request.chapterId);
    if (book.group !== chapter.group || book.book !== chapter.book) {
      throw new Error("Chapter does not belong to the requested content.");
    }
    const url = chapterUrl(chapter);
    const html = await this.#fetchHtml(url);
    const title = textFromMatch(html, /<h1\s+class=["'][^"']*title[^"']*["'][^>]*>([\s\S]*?)<\/h1>/iu);
    const contentHtml = firstCapture(html, /<div\s+class=["'][^"']*content[^"']*["'][^>]*\bid=["']content["'][^>]*>([\s\S]*?)<\/div>/iu) ?? firstCapture(html, /<div\s+id=["']content["'][^>]*>([\s\S]*?)<\/div>/iu) ?? "";
    const raw = contentHtml.replace(/<script\b[\s\S]*?<\/script>/giu, "").replace(/<style\b[\s\S]*?<\/style>/giu, "").replace(/<br\s*\/?\s*>/giu, "\n").replace(/<p(?:\s[^>]*)?>/giu, "\n").replace(/<\/p\s*>/giu, "\n");
    const decoded = decodeHtml(stripTags(raw));
    const paragraphs = decoded.split(/\r?\n/u).map(compact).filter((line) => line.length !== 0 && !isBoilerplate(line));
    return {
      chapterId: request.chapterId,
      contentKind: "novel",
      title,
      updatedAt: null,
      text: paragraphs.join("\n\n"),
      pages: []
    };
  }
  #parseRowBooks(html, pageUrl) {
    const results = [];
    const seen = /* @__PURE__ */ new Set();
    for (const root of captures(html, /<li\b[^>]*>([\s\S]*?)<\/li>/giu)) {
      const titleLink = firstLink(classBlock(root, "s2") ?? "", /\/kanshu\/\d+\/\d+\//u);
      const url = normalizeSourceUrl(titleLink?.href, pageUrl);
      const title = titleLink?.title ?? null;
      if (url === null || title === null) continue;
      const key = bookKeyFromUrl(url);
      const id = encodeBookId(key);
      if (seen.has(id)) continue;
      seen.add(id);
      const latestLink = firstLink(classBlock(root, "s3") ?? "", /\.html(?:[?#]|$)/u);
      const latestUrl = normalizeSourceUrl(latestLink?.href, pageUrl);
      const latestTitle = latestLink?.title ?? null;
      const category = stripBrackets(textFromHtml(classBlock(root, "s1") ?? ""));
      results.push(summary({
        key,
        title,
        author: textFromHtml(classBlock(root, "s4") ?? ""),
        category,
        coverUrl: this.#coverProxy(coverUrl(key)),
        description: null,
        status: "unknown",
        chapterCount: null,
        latestChapter: latestUrl === null || latestTitle === null ? null : { id: chapterIdFromUrl(latestUrl), title: latestTitle, url: latestUrl.toString(), updatedAt: null }
      }));
    }
    return results;
  }
  #parseCategoryBooks(html, pageUrl) {
    const results = [];
    const seen = /* @__PURE__ */ new Set();
    for (const root of captures(html, /<div\s+class=["'][^"']*\bitem\b[^"']*["'][^>]*>([\s\S]*?<\/dl>)\s*<\/div>/giu)) {
      const titleLink = firstLink(firstCapture(root, /<dt[^>]*>([\s\S]*?)<\/dt>/iu) ?? "", /\/kanshu\/\d+\/\d+\//u);
      const url = normalizeSourceUrl(titleLink?.href, pageUrl);
      const title = titleLink?.title ?? null;
      if (url === null || title === null) continue;
      const key = bookKeyFromUrl(url);
      const id = encodeBookId(key);
      if (seen.has(id)) continue;
      seen.add(id);
      const imageTag = firstCapture(root, /(<img\b[^>]*>)/iu);
      const authorBlock = firstCapture(root, /<dt[^>]*>[\s\S]*?<span[^>]*>([\s\S]*?)<\/span>/iu) ?? "";
      results.push(summary({
        key,
        title,
        author: textFromHtml(authorBlock),
        category: null,
        coverUrl: this.#coverProxy(normalizeCoverUrl(imageTag === null ? void 0 : attribute(imageTag, "src"), pageUrl) ?? coverUrl(key)),
        description: textFromMatch(root, /<dd[^>]*>([\s\S]*?)<\/dd>/iu),
        status: "unknown",
        chapterCount: null,
        latestChapter: null
      }));
    }
    if (results.length !== 0) return results;
    return this.#parseRowBooks(html, pageUrl);
  }
  #parseChapterPage(html, pageUrl, key) {
    const expectedPrefix = `/kanshu/${key.group}/${key.book}/`;
    const scope = firstCapture(
      html,
      /<h2\s+class=["'][^"']*layout-tit[^"']*["'][^>]*>[^<]*正文<\/h2>\s*<div\s+class=["'][^"']*section-box[^"']*["'][^>]*>([\s\S]*?)<\/div>/iu
    ) ?? "";
    const results = [];
    for (const link of links(scope)) {
      const url = normalizeSourceUrl(link.href, pageUrl);
      const title = link.title;
      if (url === null || title === null || !url.pathname.startsWith(expectedPrefix) || !/\/\d+\.html$/u.test(url.pathname)) continue;
      results.push({
        id: chapterIdFromUrl(url),
        title,
        url: url.toString(),
        volumeTitle: null,
        wordCount: null,
        updatedAt: null,
        isLocked: false,
        attributes: []
      });
    }
    return results;
  }
  async #fetchHtml(url) {
    assertSourceUrl(url);
    const response = await this.#context.http.fetch(url, { method: "GET", proxyMode: "direct", signal: AbortSignal.timeout(15e3) });
    if (!response.ok) throw new Error("Source request failed.");
    return response.text();
  }
  #coverProxy(url) {
    if (url === null) return null;
    return this.#context.resource.proxy({ kind: "image", url: url.toString(), proxyMode: "direct", headers: { Accept: "image/*" } });
  }
};
function summary(input) {
  return {
    id: encodeBookId(input.key),
    title: input.title,
    contentKind: "novel",
    author: input.author,
    url: bookUrl(input.key).toString(),
    coverUrl: input.coverUrl,
    description: input.description,
    language: "zh-CN",
    status: input.status,
    access: "free",
    wordCount: null,
    chapterCount: input.chapterCount,
    publishedAt: null,
    updatedAt: null,
    latestChapter: input.latestChapter,
    categories: input.category === null ? [] : [input.category],
    tags: [],
    attributes: []
  };
}
function toDiscoveryItem(content) {
  return { content, rank: null, metric: null, recommendation: null };
}
function boundedPageSize(value) {
  if (!Number.isSafeInteger(value) || value <= 0) throw new Error("Page size is invalid.");
  return Math.min(value, 50);
}
function decodeCategory(target) {
  const id = target.startsWith("category:") ? target.slice("category:".length) : "";
  const category = categories.find((candidate) => candidate.id === id);
  if (category === void 0) throw new Error("Discovery target is invalid.");
  return category;
}
function decodePageCursor(cursor) {
  if (cursor === null) return 1;
  if (!/^\d+$/u.test(cursor)) throw new Error("Discovery cursor is invalid.");
  const page = Number(cursor);
  if (!Number.isSafeInteger(page) || page < 1 || page > 1e4) throw new Error("Discovery cursor is invalid.");
  return page;
}
function findNextCategoryPage(html, categoryId, currentPage) {
  const expected = currentPage + 1;
  const expectedPath = `/ksl/${categoryId}/${expected}.html`;
  const found = links(html).some((link) => new URL(link.href, sourceOrigin).pathname === expectedPath);
  return found ? expected : null;
}
function catalogPageUrls(html, firstUrl) {
  const urls = [firstUrl];
  const seen = /* @__PURE__ */ new Set([firstUrl.toString()]);
  for (const tag of html.match(/<option\b[^>]*>/giu) ?? []) {
    const url = normalizeSourceUrl(attribute(tag, "value"), firstUrl);
    if (url !== null && !seen.has(url.toString())) {
      seen.add(url.toString());
      urls.push(url);
    }
  }
  return urls;
}
function parseChapterCount(html) {
  const values = [...html.matchAll(/<option\b[^>]*>([\s\S]*?)<\/option>/giu)].flatMap((match) => {
    const range = decodeHtml(stripTags(match[1] ?? "")).match(/-\s*(\d+)\s*章/u);
    return range === null ? [] : [Number(range[1])];
  });
  return values.length === 0 ? null : Math.max(...values);
}
function prefixedValue(lines, prefix) {
  const line = lines.find((candidate) => candidate.startsWith(prefix));
  return line === void 0 ? null : text(line.slice(prefix.length));
}
function contentStatus(value) {
  if (value === null) return "unknown";
  if (/完结|完本/u.test(value)) return "completed";
  if (/连载/u.test(value)) return "ongoing";
  if (/停更|暂停/u.test(value)) return "hiatus";
  return "unknown";
}
function normalizeDescription(value) {
  return value === null ? null : text(value.replace(/^简介[：:]?/u, ""));
}
function stripBrackets(value) {
  return value === null ? null : text(value.replace(/^\[/u, "").replace(/\]$/u, ""));
}
function compact(value) {
  return value.replace(/\u00a0/gu, " ").replace(/\s+/gu, " ").trim();
}
function text(value) {
  const normalized = compact(value);
  return normalized.length === 0 ? null : normalized;
}
function isBoilerplate(value) {
  return /本章未完|加入书签|推荐本书|返回目录|章节报错|下一章|上一章/u.test(value);
}
function captures(input, pattern) {
  return [...input.matchAll(pattern)].flatMap((match) => match[1] === void 0 ? [] : [match[1]]);
}
function firstCapture(input, pattern) {
  return input.match(pattern)?.[1] ?? null;
}
function classBlock(input, className) {
  const escaped = escapeRegExp(className);
  return firstCapture(
    input,
    new RegExp(`<span\\s+class=["'][^"']*\\b${escaped}\\b[^"']*["'][^>]*>([\\s\\S]*?)<\\/span>`, "iu")
  );
}
function textFromMatch(input, pattern) {
  const value = firstCapture(input, pattern);
  return value === null ? null : textFromHtml(value);
}
function textFromHtml(input) {
  return text(decodeHtml(stripTags(input)));
}
function links(input) {
  return [...input.matchAll(/<a\b([^>]*)>([\s\S]*?)<\/a>/giu)].flatMap((match) => {
    const href = attribute(match[1] ?? "", "href");
    if (href === void 0) return [];
    return [{ href, title: textFromHtml(match[2] ?? "") }];
  });
}
function firstLink(input, hrefPattern) {
  return links(input).find((link) => hrefPattern.test(link.href));
}
function attribute(tag, name) {
  const escaped = escapeRegExp(name);
  const match = tag.match(new RegExp(`\\b${escaped}\\s*=\\s*(["'])([\\s\\S]*?)\\1`, "iu"));
  return match?.[2] === void 0 ? void 0 : decodeHtml(match[2]);
}
function stripTags(input) {
  return input.replace(/<[^>]+>/gu, "");
}
function decodeHtml(input) {
  const named = {
    amp: "&",
    apos: "'",
    gt: ">",
    lt: "<",
    nbsp: " ",
    quot: '"'
  };
  return input.replace(/&(#(?:x[0-9a-f]+|\d+)|[a-z]+);/giu, (entity, body) => {
    const normalized = body.toLowerCase();
    if (normalized.startsWith("#x")) return codePoint(Number.parseInt(normalized.slice(2), 16), entity);
    if (normalized.startsWith("#")) return codePoint(Number.parseInt(normalized.slice(1), 10), entity);
    return named[normalized] ?? entity;
  });
}
function codePoint(value, fallback) {
  return Number.isSafeInteger(value) && value >= 0 && value <= 1114111 ? String.fromCodePoint(value) : fallback;
}
function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
}
function encodeBookId(key) {
  return `novel:${key.group}:${key.book}`;
}
function decodeBookId(id) {
  const match = id.match(/^novel:(\d+):(\d+)$/u);
  if (match === null) throw new Error("Content ID is invalid.");
  return { group: match[1], book: match[2] };
}
function bookKeyFromUrl(url) {
  const match = url.pathname.match(/^\/kanshu\/(\d+)\/(\d+)\//u);
  if (match === null) throw new Error("Source content URL is invalid.");
  return { group: match[1], book: match[2] };
}
function chapterIdFromUrl(url) {
  const key = chapterKeyFromUrl(url);
  return `chapter:${key.group}:${key.book}:${key.chapter}`;
}
function decodeChapterId(id) {
  const match = id.match(/^chapter:(\d+):(\d+):(\d+)$/u);
  if (match === null) throw new Error("Chapter ID is invalid.");
  return { group: match[1], book: match[2], chapter: match[3] };
}
function chapterKeyFromUrl(url) {
  const match = url.pathname.match(/^\/kanshu\/(\d+)\/(\d+)\/(\d+)\.html$/u);
  if (match === null) throw new Error("Source chapter URL is invalid.");
  return { group: match[1], book: match[2], chapter: match[3] };
}
function bookUrl(key) {
  return new URL(`/kanshu/${key.group}/${key.book}/`, sourceOrigin);
}
function chapterUrl(key) {
  return new URL(`/kanshu/${key.group}/${key.book}/${key.chapter}.html`, sourceOrigin);
}
function coverUrl(key) {
  return new URL(`/files/article/image/${key.group}/${key.book}/${key.book}s.jpg`, sourceOrigin);
}
function normalizeSourceUrl(value, base) {
  if (value === void 0 || value.trim().length === 0) return null;
  const url = new URL(value, base);
  assertSourceUrl(url);
  return url;
}
function normalizeCoverUrl(value, base) {
  if (value === void 0 || value.trim().length === 0) return null;
  const url = new URL(value, base);
  if (!["http:", "https:"].includes(url.protocol) || url.username !== "" || url.password !== "" || url.port !== "" || !["www.elkoparts.net", "www.elkoparts.info"].includes(url.hostname)) throw new Error("Source cover URL is outside the allowed origin.");
  return url;
}
function assertSourceUrl(url) {
  if (url.origin !== sourceOrigin || url.protocol !== "http:") throw new Error("Source URL is outside the allowed origin.");
}

// src/index.mts
var deferredGroups = true;
var context;
var source;
async function activate(nextContext) {
  context = nextContext;
  source = new ElkopartsSource(nextContext);
  nextContext.log.info("plugin_activated");
}
async function discover(request) {
  return invoke("discover", (activeSource) => activeSource.discover(request));
}
async function search(request) {
  return invoke("search", (activeSource) => activeSource.search(request));
}
async function searchSuggestions(request) {
  return invoke("search_suggestions", async (activeSource) => activeSource.searchSuggestions(request));
}
async function getDetail(request) {
  return invoke("get_detail", (activeSource) => activeSource.getDetail(request));
}
async function getChapters(request) {
  return invoke("get_chapters", (activeSource) => activeSource.getChapters(request));
}
async function getContent(request) {
  return invoke("get_content", (activeSource) => activeSource.getContent(request));
}
async function invoke(operation, action) {
  const activeContext = requireActivated(context);
  const activeSource = requireActivated(source);
  activeContext.log.info(`source_${operation}_started`);
  try {
    const result = await action(activeSource);
    activeContext.log.info(`source_${operation}_completed`);
    return result;
  } catch (error) {
    activeContext.log.warn(`source_${operation}_failed`);
    if (isRuntimeRaisedError(error)) throw error;
    throw new Error("Source operation failed.");
  }
}
function isRuntimeRaisedError(error) {
  if (error === null || typeof error !== "object") return false;
  const candidate = error;
  return candidate.name === "PluginManagerError" && typeof candidate.code === "string";
}
function requireActivated(value) {
  if (value === void 0) throw new Error("Source is not activated.");
  return value;
}
export {
  activate,
  deferredGroups,
  discover,
  getChapters,
  getContent,
  getDetail,
  search,
  searchSuggestions
};
