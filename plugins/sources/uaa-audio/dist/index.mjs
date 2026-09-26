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
function window(all, target, page, offset, size, hasNext2) {
  const values = all.slice(offset, offset + size), next = offset + values.length;
  const cursor = next < all.length ? target + ":" + page + ":" + next : hasNext2 && all.length > 0 && page < 1e4 ? target + ":" + (page + 1) + ":0" : null;
  return { values, continuation: cursor === null ? null : { target, cursor } };
}

// src/index.mts
var main = "https://www.uaa.com";
var origin = "https://www.uaa001.com";
var root = `${origin}/api/audio/app/audio/`;
var token = "eyJhbGciOiJIUzI1NiJ9.eyJpZCI6ODYwNzIxNzA0MDMxMzU4OTc2LCJ0eXBlIjoiY3VzdG9tZXIiLCJ0aW1lc3RhbXAiOjE2ODUzNzg1MTE1NzQsImV4cCI6MTY4NTk4MzMxMX0.-FX7rOJP7I10ApjeM5NVaGj57aeYnkVyopniC7U_Dv8";
var headers = Object.freeze({ Accept: "application/json,text/plain,*/*", "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8", Referer: `${main}/audio/`, "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/126.0.0.0 Safari/537.36", token });
var channels = Object.freeze([{ id: "latest", title: "最新", path: "search", parameters: { category: "", orderType: "0", searchType: "1" } }, { id: "novel", title: "有声小说", path: "search", parameters: { category: "有声小说", orderType: "1", searchType: "1" } }, { id: "asmr", title: "ASMR", path: "search", parameters: { category: "ASMR", orderType: "1", searchType: "1" } }, { id: "songs", title: "淫词艳曲", path: "search", parameters: { category: "淫词艳曲", orderType: "1", searchType: "1" } }, { id: "voice", title: "激情骚麦", path: "search", parameters: { category: "激情骚麦", orderType: "1", searchType: "1" } }, { id: "training", title: "寸止训练", path: "search", parameters: { category: "寸止训练", orderType: "1", searchType: "1" } }, { id: "weekly", title: "周榜", path: "rank", parameters: { type: "1" } }, { id: "monthly", title: "月榜", path: "rank", parameters: { type: "2" } }, { id: "yearly", title: "年榜", path: "rank", parameters: { type: "3" } }, { id: "all-time", title: "总榜", path: "rank", parameters: { type: "4" } }]);
var context;
var throttle = Promise.resolve();
var earliest = 0;
async function activate(next) {
  context = next;
  throttle = Promise.resolve();
  earliest = 0;
  next.log.info("source_activated");
}
async function search(request) {
  const query = request.query.trim();
  if (query === "") return frozen({ items: [], nextCursor: null, totalCount: 0 });
  const page = cursorPage(request.cursor, "search"), size = clamp(request.pageSize), result = await fetchPage("search", { category: "", keyword: query, orderType: "0", page: String(page), searchType: "1", size: String(size) }), items = summaries(result.items).slice(0, size);
  return frozen({ items, nextCursor: hasNext(result, page, items.length, size) ? `search:${page + 1}` : null, totalCount: result.totalCount });
}
async function searchSuggestions(_request) {
  return frozen({ items: [], nextCursor: null });
}
async function discover(request) {
  if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null) throw new Error("Initial discovery request is invalid.");
    const components = [];
    for (const id of ["latest", "weekly"]) {
      const result2 = await discover({ target: "channel:" + id, cursor: null, collectionId: null, pageSize: Math.min(6, clamp(request.pageSize)) });
      if (result2.kind === "document") components.push(...result2.document.components);
    }
    components.push({ type: "section", id: "audio-channels", title: "分类与排行榜", subtitle: null, icon: "explore", children: [{ type: "categoryCollection", id: "audio-channel-list", layout: "chips", categories: channels.map((channel2) => ({ id: channel2.id, title: channel2.title, target: "channel:" + channel2.id, count: null, url: null, icon: channel2.path === "rank" ? "ranking" : "audio" })) }] });
    return { kind: "document", document: { components } };
  }
  const channel = channels.find((value) => request.target === "channel:" + value.id);
  if (!channel) throw new Error("Discovery target is invalid.");
  const collectionId = "audio:" + channel.id;
  if (request.collectionId !== null && request.collectionId !== collectionId) throw new Error("Discovery collection is invalid.");
  const { page, offset } = position(request.cursor, request.target), upstreamSize = 30;
  const result = await fetchPage(channel.path, { ...channel.parameters, page: String(page), size: String(upstreamSize) }), all = summaries(result.items);
  const { values, continuation } = window(all, request.target, page, offset, clamp(request.pageSize), hasNext(result, page, result.items.length, upstreamSize));
  const items = values.map((content, index) => ({ content, rank: channel.path === "rank" ? (page - 1) * upstreamSize + offset + index + 1 : null, metric: null, recommendation: null }));
  if (request.collectionId !== null) return { kind: "append", collectionId, items, continuation };
  return { kind: "document", document: { components: [{ type: "section", id: collectionId + ":section", title: channel.title, subtitle: null, icon: channel.path === "rank" ? "ranking" : "audio", children: [{ type: "contentCollection", id: collectionId, layout: channel.path === "rank" ? "compact" : "coverGrid", items, continuation }] }] } };
}
async function getDetail(request) {
  const id = contentId(request.id), model = object((await fetchJson("intro", { id, force: "false", viewId: viewId() })).model), item = summary(model, id);
  return frozen({ ...item, aliases: [], catalogUrl: `${root}catalog/${encodeURIComponent(id)}` });
}
async function getChapters(request) {
  const id = contentId(request.id), model = object((await fetchJson(`catalog/${encodeURIComponent(id)}`, {})).model), items = records(model.menus).filter((item) => item.hide !== true && number(item.hide) !== 1).map((item, index) => chapter(id, item, index)).filter(notNull);
  return frozen({ items, groups: items.length === 0 ? [] : [frozen({ id: `group:${id}:main`, title: "节目", order: 0, episodes: items })] });
}
async function getContent(request) {
  const audioId = contentId(request.id), chapter2 = chapterNative(request.chapterId, audioId), model = object((await fetchJson("chapter", { force: "false", id: chapter2, offset: "0", viewId: viewId(), audioId })).model), upstream = text(model.url);
  if (!safeUrl(upstream)) throw new Error("Audio address is unavailable.");
  const mediaHeaders = { Referer: `${origin}/audio/`, "User-Agent": headers["User-Agent"] };
  return frozen({ chapterId: request.chapterId, contentKind: "audio", title: nullable(model.title), updatedAt: timestamp(model.updateTime), text: null, pages: [], media: { url: requireContext().resource.proxy({ kind: "audio", url: upstream, headers: mediaHeaders }), resourceType: "audio", resourcePolicy: "sessionOnly", expiresAt: null, mimeType: /\.m4a(?:$|[?#])/iu.test(upstream) ? "audio/mp4" : "audio/mpeg", headers: mediaHeaders } });
}
async function fetchPage(path, params) {
  const response = await fetchJson(path, params), model = response.model;
  if (Array.isArray(model)) return { items: model.filter(isObject), totalCount: model.length, totalPage: 1 };
  const value = object(model);
  return { items: records(value.data), totalCount: nonNegative(value.totalCount), totalPage: positive(value.totalPage) };
}
async function fetchJson(path, params) {
  const url = new URL(path, root);
  for (const [key, value2] of Object.entries(params)) url.searchParams.set(key, value2);
  const response = await throttled(url.toString());
  if (!response.ok) throw new Error("Source request failed.");
  const raw = await response.text();
  let value;
  try {
    value = JSON.parse(raw);
  } catch {
    throw new Error("Source response is invalid.");
  }
  if (!isObject(value) || value.result !== "success") throw new Error("Source response indicates failure.");
  return value;
}
async function throttled(url) {
  let release = () => {
  };
  const previous = throttle;
  throttle = new Promise((resolve) => {
    release = resolve;
  });
  await previous;
  try {
    const delay = Math.max(0, earliest - Date.now());
    if (delay > 0) await new Promise((resolve) => setTimeout(resolve, delay));
    earliest = Date.now() + 300;
    return await requireContext().http.fetch(url, { headers });
  } finally {
    release();
  }
}
function summaries(values) {
  const result = /* @__PURE__ */ new Map();
  for (const value of values) {
    const id = sourceId(first(value.id, value.audioId));
    if (id !== null && text(value.title) !== "") result.set(id, summary(value, id));
  }
  return [...result.values()];
}
function summary(value, id) {
  const encoded = sourceId(id);
  if (encoded === null) throw new Error("Audio ID is invalid.");
  const title = text(value.title) || id, author = nullable(first(value.authors, value.uploader)), finished = number(value.finished) === 1, latestId = sourceId(value.latestReadChapterId);
  return frozen({ id: `audio:${encoded}`, title, contentKind: "audio", coverOrientation: "portrait", author, url: `${root}intro?id=${encodeURIComponent(id)}`, coverUrl: proxyImage(text(value.coverUrl)), description: nullable(first(value.shortBrief, value.brief, value.description)), language: "zh-CN", status: finished ? "completed" : "ongoing", access: number(value.vip) === 1 ? "paid" : "unknown", wordCount: null, chapterCount: nonNegative(value.chapterCount), publishedAt: timestamp(value.onlineTime), updatedAt: timestamp(first(value.updateTime, value.updateTimeFormat)), latestChapter: latestId === null ? null : { id: `audio:${id}:${latestId}`, title: text(first(value.latestUpdate, value.latestReadChapter)) || "最新节目", url: null, updatedAt: null }, categories: stringList(value.categories), tags: [], attributes: [] });
}
function chapter(audioId, value, index) {
  const id = sourceId(value.id);
  if (id === null || text(value.title) === "") return null;
  return frozen({ id: `audio:${audioId}:${id}`, title: text(value.title), order: index, url: null, volumeTitle: "节目", wordCount: null, updatedAt: timestamp(value.onlineTime), isLocked: number(value.vip) === 1, attributes: [] });
}
function sourceId(value) {
  const id = text(value);
  return /^\d{6,}$/u.test(id) ? id : null;
}
function contentId(id) {
  const value = /^audio:(\d+)$/u.exec(id)?.[1];
  if (value === void 0) throw new Error("Content ID is invalid.");
  return value;
}
function chapterNative(id, audioId) {
  const value = new RegExp(`^audio:${audioId}:(\\d+)$`, "u").exec(id)?.[1];
  if (value === void 0) throw new Error("Chapter ID is invalid.");
  return value;
}
function proxyImage(value) {
  if (!safeUrl(value)) return null;
  return requireContext().resource.proxy({ kind: "image", url: value, headers: { Referer: `${origin}/audio/` } });
}
function safeUrl(value) {
  try {
    const url = new URL(value);
    return (url.protocol === "https:" || url.protocol === "http:") && url.username === "" && url.password === "";
  } catch {
    return false;
  }
}
function viewId() {
  return `${Date.now()}${Math.floor(Math.random() * 9e3 + 1e3)}`;
}
function hasNext(result, page, count, size) {
  return result.totalPage !== null ? page < result.totalPage : result.totalCount !== null ? page * size < result.totalCount : count >= size;
}
function cursorPage(cursor, target) {
  if (cursor === null) return 1;
  const raw = cursor.startsWith(`${target}:`) ? cursor.slice(target.length + 1) : "", page = Number(raw);
  if (!Number.isSafeInteger(page) || page < 2 || page > 1e3) throw new Error("Cursor is invalid.");
  return page;
}
function stringList(value) {
  if (Array.isArray(value)) return value.map(text).filter(Boolean).slice(0, 32);
  const raw = text(value);
  return raw === "" ? [] : raw.split(/[,，/]/u).map((part) => part.trim()).filter(Boolean).slice(0, 32);
}
function timestamp(value) {
  const raw = text(value);
  if (raw === "") return null;
  const date = new Date(raw);
  return Number.isNaN(date.valueOf()) ? null : date.toISOString();
}
function positive(value) {
  const n = Number(value);
  return Number.isSafeInteger(n) && n > 0 ? n : null;
}
function nonNegative(value) {
  const n = Number(value);
  return Number.isSafeInteger(n) && n >= 0 ? n : null;
}
function first(...values) {
  return values.find((value) => value !== null && value !== void 0 && value !== "") ?? "";
}
function records(value) {
  return Array.isArray(value) ? value.filter(isObject) : [];
}
function object(value) {
  return isObject(value) ? value : {};
}
function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
function text(value) {
  return typeof value === "string" ? value.trim() : typeof value === "number" || typeof value === "bigint" ? String(value) : "";
}
function number(value) {
  const result = Number(value);
  return Number.isFinite(result) ? result : 0;
}
function nullable(value) {
  const result = text(value);
  return result === "" ? null : result;
}
function notNull(value) {
  return value !== null;
}
function clamp(value) {
  return Math.max(1, Math.min(50, Math.floor(value)));
}
function frozen(value) {
  return Object.freeze(value);
}
function requireContext() {
  if (context === void 0) throw new Error("Source is not activated.");
  return context;
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
