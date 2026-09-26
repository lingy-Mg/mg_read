import { createRequire as __mgreadCreateRequire } from 'node:module'; const require = __mgreadCreateRequire(import.meta.url);

// src/index.mts
import { createHash as createHash2 } from "node:crypto";

// ../../../packages/mg_read_plugin_cache/index.js
import { createHash, randomUUID } from "node:crypto";
import { mkdir, readdir, readFile, rename, rm, stat, utimes, writeFile } from "node:fs/promises";
import { isAbsolute, resolve } from "node:path";
var schemaVersion = 2;
var directoryName = "plugin-cache-v2";
var maximumCacheBytes = 100 * 1024 * 1024;
var maximumEntryBytes = 1024 * 1024;
var cacheFilePattern = /^[a-f0-9]{64}\.json$/u;
var PluginCache = class {
  #root;
  #now;
  #maximumCacheBytes;
  #maximumEntryBytes;
  #logger;
  #inflight = /* @__PURE__ */ new Map();
  #backgroundRefreshes = /* @__PURE__ */ new Map();
  constructor(cacheDir, options = {}) {
    this.#root = isAbsolute(cacheDir) ? resolve(cacheDir, directoryName) : void 0;
    this.#now = options.now ?? Date.now;
    this.#maximumCacheBytes = positiveLimit(options.maximumCacheBytes ?? maximumCacheBytes);
    this.#maximumEntryBytes = positiveLimit(options.maximumEntryBytes ?? maximumEntryBytes);
    this.#logger = options.logger;
    this.#debug("缓存已启用");
  }
  getOrFetchText(url, policy, fetcher) {
    return this.getOrFetchTextResult(url, policy, fetcher).then((result) => result.value);
  }
  getOrFetchTextResult(url, policy, fetcher) {
    return this.#getOrFetch(cacheKey(policy.namespace, url), policy, async () => ({ value: await fetcher(), storedAtMs: this.#now() }), asText);
  }
  getOrFetchJson(cacheKeyInput, policy, fetcher, decode) {
    return this.getOrFetchJsonResult(cacheKeyInput, policy, fetcher, decode).then((result) => result.value);
  }
  getOrFetchJsonResult(cacheKeyInput, policy, fetcher, decode) {
    if (typeof cacheKeyInput !== "string" || cacheKeyInput.length === 0 || cacheKeyInput.length > 512) throw new Error("Cache key is invalid.");
    return this.#getOrFetch(cacheKey(policy.namespace, cacheKeyInput), policy, fetcher, decode);
  }
  #getOrFetch(key, policy, fetcher, decode) {
    if (this.#root === void 0) return fetcher();
    const existing = this.#inflight.get(key);
    if (existing !== void 0) {
      this.#debug("缓存合并进行中的请求");
      return existing;
    }
    const pending = this.#readOrFetch(key, policy, fetcher, decode);
    this.#inflight.set(key, pending);
    void pending.then(() => this.#inflight.delete(key), () => this.#inflight.delete(key));
    return pending;
  }
  async #readOrFetch(key, policy, fetcher, decode) {
    const cached = await this.#read(key, decode);
    if (cached !== void 0 && this.#now() - cached.storedAtMs <= policy.staleAfterMs) {
      this.#debug(`缓存命中：命名空间=${policy.namespace}`);
      void this.#touch(key);
      return cached;
    }
    if (cached !== void 0 && policy.serveStaleWhileRevalidate === true) {
      this.#debug(`缓存命中旧数据并后台刷新：命名空间=${policy.namespace}`);
      void this.#refreshInBackground(key, fetcher);
      void this.#touch(key);
      return cached;
    }
    const backgroundRefresh = this.#backgroundRefreshes.get(key);
    if (backgroundRefresh !== void 0) {
      this.#debug(`等待缓存刷新：命名空间=${policy.namespace}`);
      await backgroundRefresh;
      const refreshed = await this.#read(key, decode);
      if (refreshed !== void 0 && this.#now() - refreshed.storedAtMs <= policy.staleAfterMs) return refreshed;
    }
    try {
      this.#debug(`缓存未命中：命名空间=${policy.namespace}`);
      const fetched = await fetcher();
      const storedAtMs = validStoredAt(fetched.storedAtMs) ? fetched.storedAtMs : this.#now();
      await this.#write(key, fetched.value, storedAtMs);
      this.#debug(`缓存请求完成：命名空间=${policy.namespace}`);
      return Object.freeze({ value: fetched.value, storedAtMs });
    } catch (error) {
      if (cached !== void 0 && policy.allowStaleOnError !== false) {
        this.#warn(`缓存请求失败，回退旧数据：命名空间=${policy.namespace}`);
        return cached;
      }
      this.#warn(`缓存请求失败：命名空间=${policy.namespace}`);
      throw error;
    }
  }
  #refreshInBackground(key, fetcher) {
    const existing = this.#backgroundRefreshes.get(key);
    if (existing !== void 0) return existing;
    const refresh = (async () => {
      try {
        this.#debug("cache_refresh_started");
        const fetched = await fetcher();
        await this.#write(key, fetched.value, validStoredAt(fetched.storedAtMs) ? fetched.storedAtMs : this.#now());
        this.#debug("cache_refresh_completed");
      } catch {
        this.#warn("cache_refresh_failed");
      }
    })();
    this.#backgroundRefreshes.set(key, refresh);
    void refresh.then(() => this.#backgroundRefreshes.delete(key), () => this.#backgroundRefreshes.delete(key));
    return refresh;
  }
  async #read(key, decode) {
    try {
      const path = this.#entryPath(key);
      const metadata = await stat(path);
      if (!metadata.isFile() || metadata.size > this.#maximumEntryBytes) return void 0;
      const record = JSON.parse(await readFile(path, "utf8"));
      if (!isRecord(record) || record.schemaVersion !== schemaVersion || !validStoredAt(record.storedAtMs)) return void 0;
      const value = decode(record.value);
      if (value === void 0 || byteLength(record) > this.#maximumEntryBytes) return void 0;
      return Object.freeze({ value, storedAtMs: record.storedAtMs });
    } catch {
      return void 0;
    }
  }
  async #write(key, value, storedAtMs) {
    if (this.#root === void 0) return;
    const temporary = resolve(this.#root, `.${key}.${randomUUID()}.partial`);
    try {
      await mkdir(this.#root, { recursive: true });
      const encoded = JSON.stringify({ schemaVersion, storedAtMs, value });
      if (Buffer.byteLength(encoded, "utf8") > this.#maximumEntryBytes) {
        this.#warn("cache_write_skipped_entry_too_large");
        return;
      }
      await writeFile(temporary, encoded, "utf8");
      await rename(temporary, this.#entryPath(key));
      await this.#enforceCapacity();
      this.#debug("cache_store_completed");
    } catch {
      this.#warn("cache_write_failed");
    } finally {
      await rm(temporary, { force: true }).catch(() => void 0);
    }
  }
  async #touch(key) {
    try {
      const now = new Date(this.#now());
      await utimes(this.#entryPath(key), now, now);
    } catch {
    }
  }
  async #enforceCapacity() {
    if (this.#root === void 0) return;
    const entries = await readdir(this.#root, { withFileTypes: true });
    const candidates = await Promise.all(entries.filter((entry) => entry.isFile() && cacheFilePattern.test(entry.name)).map(async (entry) => {
      const path = resolve(this.#root, entry.name);
      const metadata = await stat(path);
      return { path, size: metadata.size, accessedAtMs: metadata.mtimeMs };
    }));
    let total = candidates.reduce((sum, entry) => sum + entry.size, 0);
    let evicted = 0;
    for (const entry of candidates.sort((left, right) => left.accessedAtMs - right.accessedAtMs)) {
      if (total <= this.#maximumCacheBytes) break;
      await rm(entry.path, { force: true });
      total -= entry.size;
      evicted += 1;
    }
    if (evicted > 0) this.#debug(`cache_capacity_evicted count=${evicted}`);
  }
  #entryPath(key) {
    if (this.#root === void 0 || !/^[a-f0-9]{64}$/u.test(key)) throw new Error("Cache key is invalid.");
    return resolve(this.#root, `${key}.json`);
  }
  #debug(message) {
    try {
      this.#logger?.debug(message);
    } catch {
    }
  }
  #warn(message) {
    try {
      this.#logger?.warn(message);
    } catch {
    }
  }
};
function cacheKey(namespace, input) {
  return createHash("sha256").update(`${namespace}
${input}`, "utf8").digest("hex");
}
function positiveLimit(value) {
  if (!Number.isSafeInteger(value) || value <= 0) throw new Error("Cache limit is invalid.");
  return value;
}
function validStoredAt(value) {
  return Number.isSafeInteger(value) && value >= 0;
}
function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function asText(value) {
  return typeof value === "string" ? value : void 0;
}
function byteLength(value) {
  try {
    return Buffer.byteLength(JSON.stringify(value), "utf8");
  } catch {
    return Number.POSITIVE_INFINITY;
  }
}

// src/index.mts
var base = "https://app.365ting.com";
var api = `${base}/listen/Apitzg2025/`;
var appHeaders = { Accept: "application/json,text/html,*/*", "User-Agent": "TingShiJie/1.8.8 (m.i275.com)" };
var coverHeaders = {
  Accept: "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8",
  Referer: base + "/",
  "User-Agent": appHeaders["User-Agent"]
};
var audioHeaders = { Accept: "*/*", "User-Agent": "okhttp/4.9.3" };
var playKey = "J9gSpfUlzYxE8Hn5IXiGaD2jVMrwAm0K";
var categories = Object.freeze([["popular", "热门", null], ["6", "玄幻", "6"], ["7", "奇幻", "7"], ["8", "武侠", "8"], ["13", "历史", "13"], ["14", "恐怖", "14"], ["31", "评书", "31"], ["50", "儿童", "50"]]);
var homeSections = [["best", "热门听书", "popular"], ["xuanhuan", "玄幻", "6"], ["qihuan", "奇幻", "7"], ["wuxia", "武侠", "8"], ["lishi", "历史", "13"], ["kongbu", "恐怖", "14"], ["pingshu", "评书", "31"], ["ertong", "儿童", "50"]];
var playbackCacheTtlMs = 10 * 60 * 1e3;
var playbackExpirySafetyMs = 5 * 1e3;
var playbackProbeTimeoutMs = 1500;
var playbackCacheMaxEntries = 256;
var chapterPageConcurrency = 6;
var chapterCacheTtlMs = 24 * 60 * 60 * 1e3;
var chapterCachePolicy = Object.freeze({ namespace: "audio-chapters-v1", staleAfterMs: chapterCacheTtlMs, serveStaleWhileRevalidate: true, allowStaleOnError: true });
var context;
var chapterLocks = /* @__PURE__ */ new Map();
var playbackCache = /* @__PURE__ */ new Map();
var playbackLocks = /* @__PURE__ */ new Map();
var chapterCache;
async function activate(next) {
  context = next;
  chapterCache = new PluginCache(next.cacheDir, { logger: next.log });
  chapterLocks.clear();
  playbackCache.clear();
  playbackLocks.clear();
  next.log.info("source_activated");
}
async function search(request) {
  if (request.cursor !== null) throw new Error("Search cursor is unsupported.");
  if (request.query.trim() === "") return frozen({ items: [], nextCursor: null, totalCount: 0 });
  const data = await fetchJson(`${api}search?search=${encodeURIComponent(request.query)}`);
  return frozen({ items: records(data.data).slice(0, clamp(request.pageSize)).map((value) => summary(value)), nextCursor: null, totalCount: null });
}
async function searchSuggestions(_request) {
  return frozen({ items: [], nextCursor: null });
}
async function discover(request) {
  if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null) throw new Error("Initial discovery request is invalid.");
    return rootDocument(request.pageSize);
  }
  if (request.target === "category:popular" || request.target.startsWith("home:")) {
    const entry = homeSections.find(([key]) => request.target === "home:" + key || key === "best" && request.target === "category:popular");
    if (entry === void 0) throw new Error("Discovery target is invalid.");
    const prefix = request.target + ":offset:";
    const raw = request.cursor?.startsWith(prefix) ? request.cursor.slice(prefix.length) : "";
    const offset = request.cursor === null ? 0 : /^\d+$/u.test(raw) ? Number(raw) : NaN;
    if (!Number.isSafeInteger(offset) || offset < 0 || offset > 1e4) throw new Error("Discovery cursor is invalid.");
    const data2 = await fetchJson(api + "appHome");
    const values2 = entry[0] === "best" ? popular(data2) : records(object(object(data2.data)[entry[0]]).list);
    return homePage(entry, request.target, values2, offset, clamp(request.pageSize), request.collectionId);
  }
  const category = categories.find(([id2]) => request.target === `category:${id2}`);
  if (category === void 0) throw new Error("Discovery target is invalid.");
  const page = pageFromCursor(request.cursor, request.target);
  const [id, label, upstreamCategory] = category;
  const url = upstreamCategory === null ? `${api}appHome` : `${api}appHomeByCategory?categoryId=${upstreamCategory}&page=${page}&size=${clamp(request.pageSize)}`;
  const data = await fetchJson(url);
  const values = upstreamCategory === null ? popular(data) : records(data.data).length > 0 ? records(data.data) : records(object(data.data).list);
  const collectionId = `audio:${id}`;
  const items = values.slice(0, clamp(request.pageSize)).map((value) => frozen({ content: summary(value), rank: null, metric: null, recommendation: null }));
  const continuation = values.length >= clamp(request.pageSize) && page < 50 ? frozen({ target: request.target, cursor: `${request.target}:${page + 1}` }) : null;
  if (request.collectionId !== null) {
    if (request.collectionId !== collectionId) throw new Error("Discovery collection is invalid.");
    return frozen({ kind: "append", collectionId, items, continuation });
  }
  return frozen({ kind: "document", document: { components: [section(collectionId, label, items, continuation)] } });
}
async function getDetail(request) {
  const id = contentId(request.id);
  const data = await fetchJson(`${api}book?bookId=${encodeURIComponent(id)}`);
  const payload = object(data.data);
  const nested = object(payload.bookData);
  const value = Object.keys(nested).length > 0 ? nested : payload;
  return detail(summary(value, id));
}
async function getChapters(request) {
  const id = contentId(request.id);
  const result = await requireChapterCache().getOrFetchJson(
    id,
    chapterCachePolicy,
    async () => ({ value: await loadChapters(id), storedAtMs: Date.now() }),
    decodeChapters
  );
  rememberChapterLocks(result.items);
  return result;
}
async function loadChapters(id) {
  const first = await chapterPage(id, 1);
  const total = positive(first.count, first.list.length);
  const pageCount = Math.min(25, Math.ceil(total / 200));
  const pages = [first, ...await chapterPages(id, pageCount)];
  const items = pages.flatMap((value) => value.list).slice(0, 5e3).map((value, order) => chapter(id, value, order));
  rememberChapterLocks(items);
  const groups = items.length === 0 ? [] : [frozen({ id: `group:${id}:default`, title: "节目", order: 0, episodes: items })];
  return frozen({ items, groups });
}
function rememberChapterLocks(items) {
  if (chapterLocks.size + items.length > 1e4) chapterLocks.clear();
  for (const item of items) chapterLocks.set(item.id, item.isLocked === true);
}
function decodeChapters(value) {
  if (!isObject(value) || !Array.isArray(value.items) || !Array.isArray(value.groups)) return void 0;
  if (!value.items.every(isObject) || !value.groups.every(isObject)) return void 0;
  return value;
}
async function chapterPages(id, pageCount) {
  const pages = [];
  for (let start = 2; start <= pageCount; start += chapterPageConcurrency) {
    const batch = await Promise.all(
      Array.from({ length: Math.min(chapterPageConcurrency, pageCount - start + 1) }, (_, offset) => chapterPage(id, start + offset))
    );
    pages.push(...batch);
  }
  return pages;
}
async function getContent(request) {
  const ctx = requireContext();
  ctx.log.info("audio_playback_resource_requested");
  try {
    const bookId = contentId(request.id);
    const chapterId = chapterIdFrom(request.chapterId, bookId);
    if (chapterLocks.get(request.chapterId) === true) throw new Error("unsupported: paid audio chapter requires an account.");
    const playback = await getPlayback(bookId, chapterId);
    const result = frozen({ chapterId: request.chapterId, contentKind: "audio", title: null, updatedAt: null, text: null, pages: [], media: {
      url: ctx.resource.proxy({ kind: "audio", url: playback.url, headers: playback.headers }),
      resourceType: "audio",
      resourcePolicy: playback.mediaExpiresAt === null ? "sessionOnly" : "refreshable",
      expiresAt: playback.mediaExpiresAt === null ? null : new Date(playback.mediaExpiresAt).toISOString(),
      mimeType: mime(playback.url),
      headers: playback.headers
    } });
    ctx.log.info("audio_playback_resource_resolved");
    return result;
  } catch (error) {
    ctx.log.warn("audio_playback_resource_failed");
    throw error;
  }
}
async function getPlayback(bookId, chapterId) {
  const key = `${bookId}:${chapterId}`;
  const pending = playbackLocks.get(key);
  if (pending !== void 0) return pending;
  const task = resolvePlayback(key, bookId, chapterId);
  playbackLocks.set(key, task);
  try {
    return await task;
  } finally {
    if (playbackLocks.get(key) === task) playbackLocks.delete(key);
  }
}
async function resolvePlayback(key, bookId, chapterId) {
  const ctx = requireContext();
  const cached = playbackCache.get(key);
  if (cached !== void 0) {
    if (cached.expiresAt <= Date.now() + playbackExpirySafetyMs) {
      playbackCache.delete(key);
      ctx.log.info("audio_playback_cache_expired");
    } else if (await probePlayback(cached)) {
      ctx.log.info("audio_playback_cache_hit");
      return cached;
    } else {
      playbackCache.delete(key);
      ctx.log.info("audio_playback_cache_probe_failed");
    }
  }
  const timestamp2 = Date.now().toString();
  const signature = md5(`${md5(`${timestamp2}${playKey}`)}${playKey}`);
  const endpoint = `${api}AppGetChapterUrl2023?timeStamp=${encodeURIComponent(timestamp2)}&uid=&chapterId=${encodeURIComponent(chapterId)}&addItParapet=${encodeURIComponent(signature)}&bookId=${encodeURIComponent(bookId)}`;
  const payload = await fetchJson(endpoint);
  const upstream = text(payload.src);
  if (!trustedAudio(upstream)) throw new Error("Playback address is unavailable.");
  const headers = { ...audioHeaders, Origin: base, Referer: `${base}/` };
  const expiry = playbackExpiry(payload, upstream);
  const resolved = { url: upstream, expiresAt: expiry.cacheExpiresAt, mediaExpiresAt: expiry.mediaExpiresAt, headers };
  if (!playbackCache.has(key) && playbackCache.size >= playbackCacheMaxEntries) {
    const oldest = playbackCache.keys().next().value;
    if (typeof oldest === "string") playbackCache.delete(oldest);
  }
  playbackCache.set(key, resolved);
  return resolved;
}
async function probePlayback(playback) {
  try {
    const response = await requireContext().http.fetch(playback.url, { method: "HEAD", headers: playback.headers, signal: AbortSignal.timeout(playbackProbeTimeoutMs) });
    return response.ok;
  } catch {
    return false;
  }
}
function playbackExpiry(payload, url) {
  const now = Date.now();
  const explicit = ["expiresAt", "expireAt", "expires", "expireTime", "expiration"].map((key) => timestamp(payload[key])).find((value) => value !== null);
  const mediaExpiresAt = explicit ?? urlExpiresAt(url);
  return { cacheExpiresAt: mediaExpiresAt ?? now + playbackCacheTtlMs, mediaExpiresAt };
}
function urlExpiresAt(value) {
  try {
    const parsed = new URL(value);
    for (const key of ["expiresAt", "expireAt", "expires", "expireTime", "expiration", "e"]) {
      const result = timestamp(parsed.searchParams.get(key));
      if (result !== null) return result;
    }
    const authKey = parsed.searchParams.get("auth_key");
    const embedded = authKey?.split("-")[1];
    return timestamp(embedded);
  } catch {
    return null;
  }
}
function timestamp(value) {
  if (value === null || value === void 0 || value === "") return null;
  const numeric = typeof value === "number" ? value : Number(value);
  if (Number.isFinite(numeric) && numeric > 0) {
    const milliseconds = numeric < 1e11 ? numeric * 1e3 : numeric;
    return milliseconds;
  }
  const parsed = Date.parse(String(value));
  return Number.isFinite(parsed) ? parsed : null;
}
async function fetchJson(url) {
  const response = await requireContext().http.fetch(url, { headers: appHeaders });
  if (!response.ok) throw new Error("Source request failed.");
  const value = await response.json();
  if (!isObject(value)) throw new Error("Source response is invalid.");
  return value;
}
async function chapterPage(id, page) {
  const data = await fetchJson(`${api}chapter?size=200&page=${page}&sort=asc&bookId=${encodeURIComponent(id)}`);
  const value = object(data.data);
  return { count: number(value.count), list: records(value.list) };
}
async function rootDocument(pageSize) {
  const data = await fetchJson(`${api}appHome`);
  const components = [];
  for (const entry of homeSections) {
    const values = entry[0] === "best" ? popular(data) : records(object(object(data.data)[entry[0]]).list);
    if (values.length === 0) continue;
    const result = homePage(entry, "home:" + entry[0], values, 0, Math.min(clamp(pageSize), 4), null);
    if (result.kind === "document") components.push(...result.document.components);
  }
  components.push({ type: "section", id: "audio-categories", title: "听书分类", subtitle: "按题材选择想听的内容", icon: "explore", children: [{ type: "categoryCollection", id: "audio-categories-list", layout: "chips", categories: categories.map(([id, title]) => ({ id, title, target: `category:${id}`, count: null, url: null, icon: "audio" })) }] });
  return frozen({ kind: "document", document: { components } });
}
function homePage(entry, target, values, offset, size, collectionId) {
  const id = "audio:" + entry[2];
  if (collectionId !== null && collectionId !== id) throw new Error("Discovery collection is invalid.");
  const items = values.slice(offset, offset + size).map((value) => ({ content: summary(value), rank: null, metric: null, recommendation: null }));
  const next = offset + items.length;
  const continuation = next < values.length ? { target, cursor: target + ":offset:" + next } : null;
  if (collectionId !== null) return { kind: "append", collectionId, items, continuation };
  return { kind: "document", document: { components: [section(id, entry[1], items, continuation, "shelf")] } };
}
function section(id, title, items, continuation, layout = "coverGrid", icon = "audio", subtitle = null) {
  return { type: "section", id: `${id}:section`, title, subtitle, icon, children: [{ type: "contentCollection", id, layout, items, continuation }] };
}
function summary(value, idOverride) {
  const id = idOverride ?? (text(value.id) || text(value.bookId));
  if (id === "") throw new Error("Source item has no ID.");
  const count = number(value.count);
  const cover = imageUrl(nullable(value.bookImage) ?? nullable(value.image));
  return frozen({ id: `audio:${id}`, title: text(value.bookTitle) || text(value.title) || "未命名音频", contentKind: "audio", coverOrientation: "portrait", author: nullable(value.bookAnchor) ?? nullable(value.anchor), url: `${base}/book/${id}`, coverUrl: cover === null ? null : requireContext().resource.proxy({ kind: "image", url: cover, headers: coverHeaders }), description: nullable(value.bookDesc) ?? nullable(value.desc), language: "zh-CN", status: status(value.bookUpdateStatus), access: "mixed", wordCount: null, chapterCount: count || null, publishedAt: null, updatedAt: null, latestChapter: count > 0 ? { id: null, title: `共${count}集`, url: null, updatedAt: null } : null, categories: nullable(value.categoryName) === null ? [] : [nullable(value.categoryName)], tags: [], attributes: [] });
}
function detail(item) {
  return frozen({ ...item, aliases: [], catalogUrl: item.url });
}
function chapter(bookId, value, order) {
  const id = text(value.chapterId) || text(value.id) || text(value.url);
  if (id === "") throw new Error("Source chapter has no ID.");
  const price = number(value.price) || number(value.chapterPrice);
  return frozen({ id: `audio:${bookId}:${id}`, title: text(value.title) || `第${order + 1}集`, order, url: `${base}/book/${encodeURIComponent(bookId)}/${encodeURIComponent(id)}`, volumeTitle: null, wordCount: null, updatedAt: null, isLocked: price > 0, attributes: price > 0 ? [{ key: "price", label: "听币", value: String(price) }] : [] });
}
function popular(data) {
  const root = object(data.data);
  return records(object(root.best).list).length > 0 ? records(object(root.best).list) : records(root.list);
}
function contentId(id) {
  const match = /^audio:([^:]+)$/u.exec(id);
  if (match?.[1] === void 0) throw new Error("Content ID is invalid.");
  return match[1];
}
function chapterIdFrom(id, bookId) {
  const match = new RegExp(`^audio:${escape(bookId)}:([^:]+)$`, "u").exec(id);
  if (match?.[1] === void 0) throw new Error("Chapter ID is invalid.");
  return match[1];
}
function pageFromCursor(cursor, target) {
  if (cursor === null) return 1;
  const value = Number(new RegExp(`^${escape(target)}:(\\d+)$`, "u").exec(cursor)?.[1]);
  if (!Number.isSafeInteger(value) || value < 2 || value > 50) throw new Error("Discovery cursor is invalid.");
  return value;
}
function trustedAudio(value) {
  try {
    const host = new URL(value).hostname.toLowerCase();
    return ["xmcdn.com", "tingshijie.com", "365ting.com", "tingchina.com", "stream.tencentmusic.com"].some((suffix) => host === suffix || host.endsWith(`.${suffix}`));
  } catch {
    return false;
  }
}
function imageUrl(value) {
  if (value === null) return null;
  try {
    const url = new URL(value, base);
    return ["http:", "https:"].includes(url.protocol) ? url.toString() : null;
  } catch {
    return null;
  }
}
function mime(url) {
  return /\.m4a(?:$|\?)/iu.test(url) ? "audio/mp4" : /\.aac(?:$|\?)/iu.test(url) ? "audio/aac" : "audio/mpeg";
}
function md5(value) {
  return createHash2("md5").update(value).digest("hex");
}
function clamp(value) {
  return Math.max(1, Math.min(100, Math.floor(value)));
}
function status(value) {
  return String(value) === "1" ? "completed" : String(value) === "2" ? "ongoing" : "unknown";
}
function positive(value, fallback) {
  return Number.isSafeInteger(value) && value > 0 ? value : fallback;
}
function object(value) {
  return isObject(value) ? value : {};
}
function records(value) {
  return Array.isArray(value) ? value.filter(isObject) : [];
}
function text(value) {
  return typeof value === "string" ? value.trim() : typeof value === "number" ? String(value) : "";
}
function nullable(value) {
  const result = text(value);
  return result === "" ? null : result;
}
function number(value) {
  const result = Number(value);
  return Number.isFinite(result) && result >= 0 ? result : 0;
}
function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
function frozen(value) {
  return Object.freeze(value);
}
function escape(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
}
function requireContext() {
  if (context === void 0) throw new Error("Source is not activated.");
  return context;
}
function requireChapterCache() {
  if (chapterCache === void 0) throw new Error("Source is not activated.");
  return chapterCache;
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
