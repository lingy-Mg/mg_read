import { createRequire as __mgreadCreateRequire } from 'node:module'; const require = __mgreadCreateRequire(import.meta.url);

// src/discovery-page.ts
function position(cursor, target) {
  if (cursor === null) return { page: 1, offset: 0 };
  const prefix = target + ":";
  const value = cursor.startsWith(prefix) ? cursor.slice(prefix.length) : "";
  const match = /^(\d+)(?::(\d+))?$/u.exec(value);
  const page = Number(match?.[1]), offset = Number(match?.[2] ?? 0);
  if (!match || !Number.isSafeInteger(page) || page < 1 || page > 1e4 || !Number.isSafeInteger(offset) || offset < 0 || offset > 1e4) throw new Error("Discovery cursor is invalid.");
  return { page, offset };
}
function window(all, target, page, offset, size, hasNext) {
  const values = all.slice(offset, offset + size), next = offset + values.length;
  const cursor = next < all.length ? target + ":" + page + ":" + next : hasNext && all.length > 0 && page < 1e4 ? target + ":" + (page + 1) + ":0" : null;
  return { values, continuation: cursor === null ? null : { target, cursor } };
}

// src/source.ts
import "node:buffer";

// src/discovery-home.ts
var rails = [{ id: "today", title: "今日漫画" }, { id: "popular", title: "热门漫画" }, { id: "recommended", title: "推荐" }];
function homeEntries(html) {
  return html.split(/<div\s+class="slider-product"[^>]*>/u).slice(1).flatMap((block) => {
    const title = decode(/<h2\b[^>]*>([\s\S]*?)<\/h2>/u.exec(block)?.[1] ?? "");
    const rail = rails.find((value) => value.title === title);
    if (!rail) return [];
    const seen = /* @__PURE__ */ new Set();
    const entries = [...block.matchAll(/<a\b([^>]*\bhref="\/webtoon\/(\d+)"[^>]*)>([\s\S]*?)<\/a>/gu)].flatMap((match) => {
      const id = match[2];
      const title2 = decode(/aria-label="([^"]+)"/u.exec(match[1])?.[1] ?? /<h4\b[^>]*>([\s\S]*?)<\/h4>/u.exec(match[3])?.[1] ?? "");
      if (!title2 || seen.has(id)) return [];
      seen.add(id);
      const images = [...match[3].matchAll(/\bsrc="([^"]+)"/gu)].map((value) => decode(value[1]));
      const thumbnail = images.flatMap((raw) => {
        try {
          const url = new URL(raw, "https://rehanman.com");
          const value = url.pathname === "/_next/image" ? url.searchParams.get("url") : url.toString();
          return value?.startsWith("https://img.rehanman.com/") ? [value] : [];
        } catch {
          return [];
        }
      })[0] ?? null;
      return [{ title: title2, title_normalized: id, thumbnail }];
    });
    return entries.length ? [{ ...rail, entries }] : [];
  });
}
function decode(value) {
  return value.replace(/<[^>]+>/gu, "").replace(/&#(x[0-9a-f]+|\d+);/giu, (_, code) => {
    const n = code[0]?.toLowerCase() === "x" ? parseInt(code.slice(1), 16) : Number(code);
    return n <= 1114111 ? String.fromCodePoint(n) : "";
  }).replaceAll("&quot;", '"').replaceAll("&#39;", "'").replaceAll("&lt;", "<").replaceAll("&gt;", ">").replaceAll("&amp;", "&").trim();
}

// src/source.ts
var siteOrigin = "https://rehanman.com";
var imageOrigin = "https://img.rehanman.com";
var graphQlUrl = "https://api.rehanman.com/manga-graphql";
var entriesQuery = "query entries($inputs: InputEntries) { entries(inputs: $inputs) { docs { title title_normalized description thumbnail authors { name } genres { name } created_date modified_date status entries_setting { premium isHide } } totalPages totalDocs page } }";
var RehanmanSource = class {
  constructor(context) {
    this.context = context;
  }
  context;
  async latest(page) {
    return this.#entries({ type: "new", page, limit: 30 });
  }
  async home() {
    const response = await this.context.http.fetch(siteOrigin + "/", { headers: { accept: "text/html" } });
    if (!response.ok) throw new Error("Source homepage is unavailable.");
    return homeEntries(await response.text()).map((rail) => ({ id: rail.id, title: rail.title, items: rail.entries.flatMap((raw) => {
      const entry = parseEntry(raw);
      return entry ? [this.#summary(entry)] : [];
    }) }));
  }
  async search(query, page) {
    return this.#entries({ type: "search", key: query, page, limit: 30 });
  }
  async detail(id) {
    const entry = await this.#entry(id);
    return Object.freeze({ ...this.#summary(entry), aliases: Object.freeze([]), catalogUrl: bookUrl(entry).toString() });
  }
  async chapters(id) {
    const entry = await this.#entry(id);
    this.#assertFree(entry);
    const chapters = entry.entries_data?.chapters ?? [];
    return Object.freeze({ items: Object.freeze(chapters.map((chapter) => Object.freeze({ id: chapterId(entry, chapter), title: chapter.name, order: chapter.index, url: chapterUrl(entry, chapter).toString(), volumeTitle: entry.entries_data?.volume_name ?? null, wordCount: null, updatedAt: entry.modified_date, isLocked: false, attributes: Object.freeze([]) }))) });
  }
  async content(id, idForChapter) {
    const entry = await this.#entry(id);
    this.#assertFree(entry);
    const chapter = (entry.entries_data?.chapters ?? []).find((value) => chapterId(entry, value) === idForChapter);
    if (chapter === void 0) throw new Error("Chapter ID is invalid.");
    const images = chapter.images.flatMap((path) => imageUrl(path) === null ? [] : [imageUrl(path)]);
    if (images.length === 0) throw new Error("Chapter images are missing.");
    const referer = chapterUrl(entry, chapter);
    return Object.freeze({ chapterId: idForChapter, contentKind: "manga", title: chapter.name, updatedAt: entry.modified_date, text: null, pages: Object.freeze(images.map((url, index) => Object.freeze({ id: `page:${index + 1}`, index, url: this.#proxyImage(url, referer), mimeType: mime(url), width: null, height: null }))) });
  }
  async #entry(id) {
    const url = bookUrlFromId(id);
    const page = await this.#page(url);
    const entry = parseEntry(object(object(page.props)?.pageProps)?.entrySSR);
    if (entry === null || entry.title_normalized !== tokenFromId(id)) throw new Error("Content detail is invalid.");
    return entry;
  }
  async #entries(inputs) {
    const response = await this.context.http.fetch(graphQlUrl, { method: "POST", headers: { accept: "application/json", "content-type": "application/json" }, body: JSON.stringify({ query: entriesQuery, variables: { inputs: { ...inputs, adult: true, is_hide: false } } }) });
    if (!response.ok) throw new Error("Source listing is unavailable.");
    const payload = object(await response.json());
    const entries = object(object(payload?.data)?.entries);
    const items = array(entries?.docs).flatMap((value) => {
      const entry = parseEntry(value);
      return entry === null ? [] : [this.#summary(entry)];
    });
    const current = number(entries?.page);
    const totalPages = number(entries?.totalPages);
    const totalCount = number(entries?.totalDocs);
    if (current === null || totalPages === null || totalCount === null) throw new Error("Source listing is invalid.");
    return Object.freeze({ items: Object.freeze(items), hasNext: current < totalPages, totalCount });
  }
  #summary(entry) {
    const cover = entry.thumbnail === null ? null : imageUrl(entry.thumbnail);
    return summary(entry, cover === null ? null : this.#proxyImage(cover, bookUrl(entry)));
  }
  async #page(url) {
    const response = await this.context.http.fetch(url, { headers: { accept: "text/html,application/xhtml+xml", referer: `${siteOrigin}/` } });
    if (!response.ok) throw new Error("Source page is unavailable.");
    return parseNextData(await response.text());
  }
  #proxyImage(url, referer) {
    if (imageUrl(url.toString()) === null || referer.origin !== siteOrigin) throw new Error("Image request is invalid.");
    return this.context.resource.proxy({ kind: "rehanman-image", url: url.toString(), headers: { Accept: "image/*", Referer: `${siteOrigin}/` } });
  }
  #assertFree(entry) {
    if (entry.entries_setting.some((setting) => setting.premium || setting.isHide)) throw new Error("Content is not publicly available.");
  }
};
function parseNextData(html) {
  const match = /<script id="__NEXT_DATA__" type="application\/json">(?<json>[\s\S]*?)<\/script>/u.exec(html);
  if (match?.groups?.json === void 0) throw new Error("Source response does not contain page data.");
  try {
    return JSON.parse(match.groups.json);
  } catch {
    throw new Error("Source page data is invalid.");
  }
}
function parseEntry(value) {
  const raw = object(value);
  const title = text(raw?.title);
  const normalized = text(raw?.title_normalized);
  if (title === null || normalized === null || !/^\d+$/u.test(normalized)) return null;
  const entryData = object(raw?.entries_data);
  const chapters = array(entryData?.chapters).flatMap((chapter) => {
    const current = object(chapter);
    const name = text(current?.name);
    const index = number(current?.index);
    const images = array(current?.images).flatMap((image) => typeof image === "string" ? [image] : []);
    return name === null || index === null ? [] : [Object.freeze({ name, index, images: Object.freeze(images) })];
  });
  return Object.freeze({ title, title_normalized: normalized, description: text(raw?.description), thumbnail: text(raw?.thumbnail), authors: names(raw?.authors), genres: names(raw?.genres), created_date: text(raw?.created_date), modified_date: text(raw?.modified_date), status: text(raw?.status), entries_data: entryData === void 0 ? null : Object.freeze({ volume_name: text(entryData.volume_name), chapters: Object.freeze(chapters) }), entries_setting: array(raw?.entries_setting).flatMap((setting) => {
    const current = object(setting);
    return typeof current?.premium === "boolean" && typeof current.isHide === "boolean" ? [Object.freeze({ premium: current.premium, isHide: current.isHide })] : [];
  }) });
}
function summary(entry, coverUrl) {
  const chapters = entry.entries_data?.chapters ?? [];
  const last = chapters.at(-1) ?? null;
  return Object.freeze({ id: contentId(entry.title_normalized), title: entry.title, contentKind: "manga", author: entry.authors[0] ?? null, url: bookUrl(entry).toString(), coverUrl, description: entry.description, language: null, status: "unknown", access: "free", wordCount: null, chapterCount: chapters.length, publishedAt: entry.created_date, updatedAt: entry.modified_date, latestChapter: { id: last === null ? `chapter:${entry.title_normalized}:none` : chapterId(entry, last), title: last?.name ?? "暂无章节", url: last === null ? bookUrl(entry).toString() : chapterUrl(entry, last).toString(), updatedAt: entry.modified_date }, categories: entry.genres, tags: entry.genres, attributes: Object.freeze([]) });
}
function contentId(token) {
  return `webtoon:${token}`;
}
function tokenFromId(id) {
  const match = /^webtoon:(\d+)$/u.exec(id);
  if (match?.[1] === void 0) throw new Error("Content ID is invalid.");
  return match[1];
}
function bookUrlFromId(id) {
  return new URL(`/webtoon/${tokenFromId(id)}`, siteOrigin);
}
function bookUrl(entry) {
  return bookUrlFromId(contentId(entry.title_normalized));
}
function chapterId(entry, chapter) {
  return `chapter:${entry.title_normalized}:${chapter.index}`;
}
function chapterUrl(entry, chapter) {
  const volume = entry.entries_data?.volume_name ?? "00";
  return new URL(`/webtoon/${entry.title_normalized}/${volume}/ch-${chapter.index + 1}`, siteOrigin);
}
function imageUrl(value) {
  try {
    const url = /^https?:\/\//iu.test(value) ? new URL(value) : new URL(`/uploads/data/china18sky/${value.replace(/^\/+/, "")}`, imageOrigin);
    return url.origin === imageOrigin && /^\/uploads\/data\/china18sky\/[\w/-]+\.(?:jpe?g|png|webp|gif)$/iu.test(url.pathname) ? url : null;
  } catch {
    return null;
  }
}
function object(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value) ? value : void 0;
}
function array(value) {
  return Array.isArray(value) ? value : [];
}
function text(value) {
  return typeof value === "string" && value.trim() !== "" ? value.trim() : null;
}
function number(value) {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 ? value : null;
}
function names(value) {
  return Object.freeze(array(value).flatMap((item) => text(object(item)?.name) ?? []));
}
function mime(url) {
  const extension = /\.([^.]+)$/u.exec(url.pathname)?.[1]?.toLowerCase();
  return extension === "jpg" || extension === "jpeg" ? "image/jpeg" : extension === "png" ? "image/png" : extension === "webp" ? "image/webp" : extension === "gif" ? "image/gif" : null;
}

// src/index.mts
var source;
async function activate(context) {
  source = new RehanmanSource(context);
  context.log.info("source_activated");
}
async function discover(request) {
  const size = Math.max(1, Math.min(50, request.pageSize));
  if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null) throw new Error("Initial discovery request is invalid.");
    const latest = await discover({ target: "latest", cursor: null, collectionId: null, pageSize: Math.min(5, size) });
    const rails2 = await requireSource().home();
    return { kind: "document", document: { components: [...latest.kind === "document" ? latest.document.components : [], ...rails2.map((rail) => railSection(rail.id, rail.title, rail.items, 0, Math.min(5, size)))] } };
  }
  if (request.target.startsWith("home:")) {
    const id = request.target.slice(5);
    if (!["today", "popular", "recommended"].includes(id)) throw new Error("Target is invalid.");
    const { page: page2, offset: offset2 } = position(request.cursor, request.target);
    if (page2 !== 1 || request.collectionId !== null && request.collectionId !== request.target) throw new Error("Discovery cursor or collection is invalid.");
    const rail = (await requireSource().home()).find((value) => value.id === id);
    if (!rail) throw new Error("Homepage section is unavailable.");
    const section = railSection(id, rail.title, rail.items, offset2, size);
    const collection = section.children[0];
    return request.collectionId === null ? { kind: "document", document: { components: [section] } } : { kind: "append", collectionId: request.target, items: collection.items, continuation: collection.continuation };
  }
  if (request.target !== "latest") throw new Error("Target is invalid.");
  if (request.collectionId !== null && request.collectionId !== "latest") throw new Error("Discovery collection is invalid.");
  const { page, offset } = position(request.cursor, "latest"), result = await requireSource().latest(page);
  const { values, continuation } = window(result.items, "latest", page, offset, size, result.hasNext);
  const items = values.map((content) => ({ content, rank: null, metric: null, recommendation: null }));
  if (request.collectionId !== null) return { kind: "append", collectionId: "latest", items, continuation };
  return { kind: "document", document: { components: [{ type: "section", id: "latest-section", title: "新漫画", subtitle: null, icon: "newRelease", children: [{ type: "contentCollection", id: "latest", layout: "coverGrid", items, continuation }] }] } };
}
function railSection(id, title, all, offset, size) {
  const target = "home:" + id, { values, continuation } = window(all, target, 1, offset, size, false);
  return { type: "section", id: target + "-section", title, subtitle: null, children: [{ type: "contentCollection", id: target, layout: "coverGrid", items: values.map((content) => ({ content, rank: null, metric: null, recommendation: null })), continuation }] };
}
async function search(request) {
  const page = parseCursor(request.cursor, "search");
  const query = request.query.trim();
  if (query === "") return Object.freeze({ items: Object.freeze([]), nextCursor: null, totalCount: 0 });
  const result = await requireSource().search(query, page);
  const items = result.items.slice(0, request.pageSize);
  return Object.freeze({ items: Object.freeze(items), nextCursor: result.hasNext && items.length === request.pageSize ? `search:${page + 1}` : null, totalCount: result.totalCount });
}
async function searchSuggestions() {
  return Object.freeze({ items: Object.freeze([]), nextCursor: null });
}
async function getDetail(request) {
  return requireSource().detail(request.id);
}
async function getChapters(request) {
  return requireSource().chapters(request.id);
}
async function getContent(request) {
  return requireSource().content(request.id, request.chapterId);
}
function requireSource() {
  if (source === void 0) throw new Error("Source is not activated.");
  return source;
}
function parseCursor(value, scope = "latest") {
  if (value === null) return 1;
  const match = new RegExp(`^${scope}:(\\d+)$`, "u").exec(value);
  const page = Number(match?.[1]);
  if (!Number.isSafeInteger(page) || page < 2) throw new Error("Cursor is invalid.");
  return page;
}
export {
  activate,
  discover,
  getChapters,
  getContent,
  getDetail,
  search,
  searchSuggestions
};
