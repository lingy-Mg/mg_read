import { createRequire as __mgreadCreateRequire } from 'node:module'; const require = __mgreadCreateRequire(import.meta.url);

// src/index.mts
import { createHmac } from "node:crypto";

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

// src/index.mts
var web = "https://www.qtfm.cn";
var graphql = "https://webbff.qtfm.cn/www";
var detailBase = "https://webapi.qtfm.cn/api/pc/radio/";
var playBase = "https://lhttp-hw.qtfm.cn";
var liveSignKey = "Lwrpu$K5oP";
var headers = Object.freeze({ Accept: "application/json,text/plain,*/*", "Content-Type": "application/json", Referer: web, "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0" });
var categories = Object.freeze([
  ["217", "广东"],
  ["99", "浙江"],
  ["3", "北京"],
  ["5", "天津"],
  ["7", "河北"],
  ["83", "上海"],
  ["19", "山西"],
  ["31", "内蒙古"],
  ["44", "辽宁"],
  ["59", "吉林"],
  ["69", "黑龙江"],
  ["85", "江苏"],
  ["111", "安徽"],
  ["129", "福建"],
  ["139", "江西"],
  ["151", "山东"],
  ["169", "河南"],
  ["187", "湖北"],
  ["202", "湖南"],
  ["239", "广西"],
  ["254", "海南"],
  ["257", "重庆"],
  ["259", "四川"],
  ["281", "贵州"],
  ["291", "云南"],
  ["316", "陕西"],
  ["327", "甘肃"],
  ["351", "宁夏"],
  ["357", "新疆"],
  ["308", "西藏"],
  ["342", "青海"],
  ["433", "资讯"],
  ["442", "音乐"],
  ["429", "交通"],
  ["439", "经济"],
  ["432", "文艺"],
  ["441", "都市"],
  ["430", "体育"],
  ["431", "双语"],
  ["440", "综合"],
  ["438", "生活"],
  ["435", "旅游"],
  ["436", "曲艺"],
  ["434", "方言"]
]);
var context;
var channels = /* @__PURE__ */ new Map();
async function activate(next) {
  context = next;
  channels.clear();
  next.log.info("source_activated");
}
async function search(request) {
  const query = request.query.trim();
  if (query === "") return frozen({ items: [], nextCursor: null, totalCount: 0 });
  const page = cursorPage(request.cursor, "search");
  const json = await graph(`{ searchResultsPage(keyword:${JSON.stringify(query)}, page:${page}, include:"channel_live") { searchData numFound } }`);
  const values = unwrap(object(object(json.data).searchResultsPage).searchData).slice(0, clamp(request.pageSize));
  return frozen({ items: values.map(summary), nextCursor: values.length >= clamp(request.pageSize) ? `search:${page + 1}` : null, totalCount: integer(object(object(json.data).searchResultsPage).numFound) });
}
async function searchSuggestions(_request) {
  return frozen({ items: [], nextCursor: null });
}
async function discover(request) {
  if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null) throw new Error("Initial discovery request is invalid.");
    const components = [];
    const result = await discover({ target: "category:3", cursor: null, collectionId: null, pageSize: Math.min(6, clamp(request.pageSize)) });
    if (result.kind === "document") components.push(...result.document.components);
    for (const [id2, title2, entries] of [["regions", "地区电台", categories.filter(([id3]) => Number(id3) < 400)], ["topics", "内容分类", categories.filter(([id3]) => Number(id3) >= 400)]]) {
      components.push({ type: "section", id: "radio-" + id2, title: title2, subtitle: null, icon: "audio", children: [{ type: "categoryCollection", id: "radio-" + id2 + "-list", layout: "chips", categories: entries.map(([id3, title3]) => ({ id: id3, title: title3, target: "category:" + id3, count: null, url: null, icon: "audio" })) }] });
    }
    return { kind: "document", document: { components } };
  }
  const category = categories.find(([id2]) => request.target === "category:" + id2);
  if (!category) throw new Error("Discovery target is invalid.");
  const [id, title] = category, collectionId = "radio:" + id;
  if (request.collectionId !== null && request.collectionId !== collectionId) throw new Error("Discovery collection is invalid.");
  const { page, offset } = position(request.cursor, request.target);
  const json = await graph("{ radioPage(cid:" + id + ", page:" + page + ") { contents } }"), all = unwrap(object(object(json.data).radioPage).contents);
  const { values, continuation } = window(all, request.target, page, offset, clamp(request.pageSize), all.length > 0);
  const items = values.map((value) => ({ content: summary(value), rank: null, metric: null, recommendation: null }));
  if (request.collectionId !== null) return { kind: "append", collectionId, items, continuation };
  return { kind: "document", document: { components: [{ type: "section", id: collectionId + ":section", title, subtitle: null, icon: "audio", children: [{ type: "contentCollection", id: collectionId, layout: "coverGrid", items, continuation }] }] } };
}
async function getDetail(request) {
  const id = contentId(request.id);
  const json = await fetchJson(`${detailBase}${encodeURIComponent(id)}`);
  const value = object(json.data);
  const item = summary({ ...value, id });
  return frozen({ ...item, aliases: [], catalogUrl: item.url });
}
async function getChapters(request) {
  const id = contentId(request.id);
  const chapter = frozen({ id: `radio:${encodeKey(id)}:live`, title: "直播", order: 0, url: null, volumeTitle: "直播", wordCount: null, updatedAt: null, isLocked: null, attributes: [] });
  return frozen({ items: [chapter], groups: [frozen({ id: `group:${encodeKey(id)}:live`, title: "直播", order: 0, episodes: [chapter] })] });
}
async function getContent(request) {
  const id = contentId(request.id);
  if (request.chapterId !== `radio:${encodeKey(id)}:live`) throw new Error("Chapter ID is invalid.");
  const resource = liveAudioResource(id);
  const mediaHeaders = { Referer: web, "User-Agent": headers["User-Agent"] };
  return frozen({ chapterId: request.chapterId, contentKind: "audio", title: "直播", updatedAt: null, text: null, pages: [], media: { url: requireContext().resource.proxy({ kind: "audio", url: resource.url, headers: mediaHeaders }), resourceType: "audio", resourcePolicy: "refreshable", expiresAt: resource.expiresAt, mimeType: "audio/mpeg", headers: mediaHeaders } });
}
async function graph(query) {
  return fetchJson(graphql, { query });
}
async function fetchJson(url, body) {
  const response = await requireContext().http.fetch(url, body === void 0 ? { headers } : { method: "POST", headers, body: JSON.stringify(body) });
  if (!response.ok) throw new Error("Source request failed.");
  const value = await response.json();
  if (!isObject(value)) throw new Error("Source response is invalid.");
  return value;
}
function summary(value) {
  const native = text(first(value.id, value.channelId, value.radioId, value.cid));
  if (native === "") throw new Error("Source item has no ID.");
  const merged = mergeChannel(channels.get(native), value);
  channels.set(native, merged);
  const id = encodeKey(native);
  const title = text(first(merged.title, merged.name, merged.channelName, merged.radioName)) || native;
  const category = nullable(first(merged.categoryName, merged.typeName));
  return frozen({ id: `radio:${id}`, title, contentKind: "audio", coverOrientation: "portrait", author: nullable(first(merged.nickName, merged.anchor, merged.dj, merged.speaker)), url: `${web}/channels/${encodeURIComponent(native)}`, coverUrl: proxyImage(first(merged.imgUrl, merged.cover, merged.coverUrl, merged.img, merged.pic, merged.logo, merged.image)), description: nullable(first(merged.description, merged.desc, merged.intro, merged.subtitle, merged.subTitle)), language: "zh-CN", status: "ongoing", access: "unknown", wordCount: null, chapterCount: 1, publishedAt: null, updatedAt: null, latestChapter: { id: `radio:${id}:live`, title: "直播", url: null, updatedAt: null }, categories: category === null ? [] : [category], tags: [], attributes: [] });
}
function unwrap(value) {
  if (typeof value === "string") {
    try {
      return unwrap(JSON.parse(value));
    } catch {
      return [];
    }
  }
  if (Array.isArray(value)) return records(value);
  if (!isObject(value)) return [];
  for (const key of ["contents", "items", "list", "data"]) {
    const result = unwrap(value[key]);
    if (result.length > 0) return result;
  }
  return [];
}
function contentId(id) {
  const encoded = /^radio:([^:]+)$/u.exec(id)?.[1];
  if (encoded === void 0) throw new Error("Content ID is invalid.");
  return decodeKey(encoded);
}
function cursorPage(cursor, target) {
  if (cursor === null) return 1;
  const match = cursor.startsWith(`${target}:`) ? cursor.slice(target.length + 1) : "";
  const page = Number(match);
  if (!Number.isSafeInteger(page) || page < 2 || page > 1e3) throw new Error("Cursor is invalid.");
  return page;
}
function absolute(value) {
  const raw = text(value);
  if (raw === "") return null;
  try {
    return new URL(raw, web).toString();
  } catch {
    return null;
  }
}
function proxyImage(value) {
  const url = absolute(value);
  return url === null ? null : requireContext().resource.proxy({ kind: "image", url, headers: { Referer: web, "User-Agent": headers["User-Agent"] } });
}
function liveAudioResource(id) {
  const path = `/live/${encodeURIComponent(id)}/64k.mp3`;
  const expiresAtSeconds = Math.floor(Date.now() / 1e3) + 3600;
  const timestamp = expiresAtSeconds.toString(16);
  const canonical = `app_id=${encodeURIComponent("web")}&path=${encodeURIComponent(path)}&ts=${encodeURIComponent(timestamp)}`;
  const sign = createHmac("md5", liveSignKey).update(canonical).digest("hex");
  const query = `app_id=${encodeURIComponent("web")}&ts=${encodeURIComponent(timestamp)}&sign=${encodeURIComponent(sign)}`;
  return frozen({ url: `${playBase}${path}?${query}`, expiresAt: new Date(expiresAtSeconds * 1e3).toISOString() });
}
function encodeKey(value) {
  return Buffer.from(value, "utf8").toString("base64url");
}
function decodeKey(value) {
  if (!/^[A-Za-z0-9_-]+$/u.test(value)) throw new Error("Source key is invalid.");
  return Buffer.from(value, "base64url").toString("utf8");
}
function first(...values) {
  return values.find((value) => value !== null && value !== void 0 && value !== "") ?? "";
}
function mergeChannel(previous, current) {
  const result = { ...previous ?? {} };
  for (const [key, value] of Object.entries(current)) if (value !== null && value !== void 0 && value !== "") result[key] = value;
  return result;
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
  return typeof value === "string" ? value.trim() : typeof value === "number" ? String(value) : "";
}
function nullable(value) {
  const result = text(value);
  return result === "" ? null : result;
}
function integer(value) {
  const result = Number(value);
  return Number.isSafeInteger(result) && result >= 0 ? result : null;
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
