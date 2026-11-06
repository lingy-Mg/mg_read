import { createRequire as __mgreadCreateRequire } from 'node:module'; const require = __mgreadCreateRequire(import.meta.url);

// src/protocol.mts
import { randomUUID } from "node:crypto";
var context;
var apiRoot = "";
var referer = "";
var session = "";
var snapshots = /* @__PURE__ */ new Map();
function initialize(next, base, origin) {
  context = next;
  apiRoot = base;
  referer = origin;
  session = randomUUID();
  snapshots.clear();
  next.log.info("source_activated");
}
async function snapshot(key, load, refresh = false) {
  const current = snapshots.get(key);
  if (!refresh && current && current.expires > Date.now()) return current.task;
  const task = Promise.resolve().then(load), entry = { expires: Date.now() + 6e4, task };
  snapshots.delete(key);
  snapshots.set(key, entry);
  while (snapshots.size > 16) snapshots.delete(snapshots.keys().next().value);
  try {
    return await task;
  } catch (error) {
    if (snapshots.get(key) === entry) snapshots.delete(key);
    throw error;
  }
}
async function remoteChapters(id, refresh = false) {
  return snapshot("chapters:" + id, async () => remoteCatalog(await json("chapters/" + id), id), refresh);
}
function ctx() {
  if (!context) throw new Error("Source is not activated.");
  return context;
}
async function json(path, body) {
  return jsonUrl(apiRoot + path, body, {
    Origin: new URL(referer).origin,
    Referer: referer,
    "x-listening-timezone": "Asia/Shanghai",
    "x-listening-session": session
  });
}
async function jsonUrl(url, body, headers = {}) {
  const response = await ctx().http.fetch(url, {
    method: body === void 0 ? "GET" : "POST",
    headers: { Accept: "application/json", ...headers, ...body === void 0 ? {} : { "Content-Type": "application/json" } },
    ...body === void 0 ? {} : { body: JSON.stringify(body) },
    signal: AbortSignal.timeout(2e4)
  });
  if (!response.ok) throw new Error("Source request failed: " + response.status);
  const value = await response.json();
  if (!object(value)) throw new Error("Source returned an invalid JSON object.");
  if (value.code !== void 0 && ![0, 200].includes(Number(value.code))) throw new Error("Source API reported failure.");
  return value;
}
var text = (value) => typeof value === "string" || typeof value === "number" ? String(value).trim() : "";
var nullable = (value) => text(value) || null;
function object(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
function records(value) {
  return Array.isArray(value) ? value.filter(object) : [];
}
function natural(value) {
  if (value === null || value === void 0 || value === "") return null;
  const n = Number(value);
  return Number.isSafeInteger(n) && n >= 0 ? n : null;
}
function native(value) {
  const id = text(value);
  if (!/^\d{1,20}$/u.test(id)) throw new Error("Invalid upstream ID.");
  return id;
}
function album(id) {
  const m = /^album:(\d{1,20})$/u.exec(id);
  if (!m) throw new Error("Invalid album ID.");
  return m[1];
}
function size(n) {
  if (!Number.isFinite(n) || n < 1) throw new Error("Invalid page size.");
  return Math.min(50, Math.floor(n));
}
function position(cursor, scope) {
  if (cursor === null) return { page: 1, offset: 0 };
  let data;
  try {
    data = JSON.parse(cursor);
  } catch {
    throw new Error("Invalid cursor.");
  }
  if (!Array.isArray(data) || data.length !== 3 || data[0] !== scope || !Number.isSafeInteger(data[1]) || data[1] < 1 || data[1] > 1e4 || !Number.isSafeInteger(data[2]) || data[2] < 0 || data[2] > 1e3) throw new Error("Invalid cursor.");
  return { page: data[1], offset: data[2] };
}
function window(values, scope, cursor, pageSize, more, step = 1) {
  const { page, offset } = position(cursor, scope);
  if (offset > values.length) throw new Error("Cursor offset exceeds source page.");
  const items = values.slice(offset, offset + size(pageSize)), end = offset + items.length;
  const nextCursor = end < values.length ? JSON.stringify([scope, page, end]) : more && page + step <= 1e4 ? JSON.stringify([scope, page + step, 0]) : null;
  return { items, nextCursor };
}
function safeUrl(value, kind) {
  try {
    const url = new URL(text(value)), suffixes = kind === "image" ? ["tingyou8.vip", "xmcdn.com", "lrts.me", "lrts.com", "365ting.com"] : ["hgeuz.cn", "365ting.com", "tingyou8.vip", "xmcdn.com", "lrts.me"];
    return ["https:", "http:"].includes(url.protocol) && !url.username && !url.password && !url.port && suffixes.some((s) => url.hostname === s || url.hostname.endsWith("." + s)) ? url.href : null;
  } catch {
    return null;
  }
}
function cover(value) {
  const url = safeUrl(value, "image");
  return url ? ctx().resource.proxy({ kind: "image", url, headers: { Referer: referer } }) : null;
}
function summary(value) {
  const id = native(value.book_id ?? value.id), title = text(value.title);
  if (!title) throw new Error("Album title is missing.");
  const categories = [...new Set([text(value.cat), text(value.type)].filter((v) => v && !["站内已有", "可提取", "需提取", "多人提取", "未分类"].includes(v)))];
  return {
    id: "album:" + id,
    title,
    contentKind: "audio",
    coverOrientation: "portrait",
    author: nullable(value.author),
    url: apiRoot + "album/" + id,
    coverUrl: cover(value.cover_url ?? value.cover),
    description: nullable(value.synopsis ?? value.description ?? value.intro ?? value.desc),
    language: "zh-CN",
    status: value.status === 0 ? "completed" : value.status === 1 ? "ongoing" : "unknown",
    access: "unknown",
    wordCount: null,
    chapterCount: natural(value.count),
    publishedAt: null,
    updatedAt: timestamp(value.updated_at),
    latestChapter: null,
    categories,
    tags: [],
    attributes: text(value.teller) ? [{ key: "narrator", label: "演播", value: text(value.teller) }] : []
  };
}
function summaries(values) {
  const map = /* @__PURE__ */ new Map();
  for (const value of values) {
    if (!/^\d{1,20}$/u.test(text(value.book_id ?? value.id)) || !text(value.title)) continue;
    const item = summary(value);
    if (!map.has(item.id)) map.set(item.id, item);
  }
  return [...map.values()];
}
function timestamp(value) {
  const n = natural(value);
  return n !== null && n > 0 && n < 1e11 ? new Date(n * 1e3).toISOString() : null;
}
function chapters(id, values, provider) {
  const seen = /* @__PURE__ */ new Set();
  return values.map((value, order) => {
    const chapterId = `${provider}:${id}:${native(value.id)}`;
    if (seen.has(chapterId)) throw new Error("Duplicate chapter ID.");
    seen.add(chapterId);
    const title = text(value.title);
    if (!title) throw new Error("Chapter title is missing.");
    return {
      id: chapterId,
      title,
      order,
      url: null,
      volumeTitle: null,
      wordCount: null,
      updatedAt: null,
      isLocked: value.is_locked === true || value.locked === true || value.is_vip === true,
      attributes: natural(value.duration) === null ? [] : [{ key: "duration", label: "时长（秒）", value: String(value.duration) }]
    };
  });
}
function remoteCatalog(data, id) {
  if (data.available === false) ctx().errors.raise("source_access_blocked");
  if (data.id !== void 0 && native(data.id) !== id) throw new Error("Catalog album ID mismatch.");
  if (!Array.isArray(data.chapters)) throw new Error("Invalid chapter catalog.");
  const values = records(data.chapters), count = natural(data.count);
  if (count !== null && count !== values.length) throw new Error("Source returned an incomplete catalog.");
  chapters(id, values, "chapter");
  if (values.some((v) => natural(v.index) === null)) throw new Error("Invalid chapter playback index.");
  return values;
}
function catalogResult(request, values) {
  if (values.length <= 5e3) {
    const groupId = "group:" + request.id + ":main";
    if (request.groupId !== void 0 && request.groupId !== groupId) throw new Error("Requested chapter group is unavailable.");
    return { items: values, groups: values.length ? [{ id: groupId, title: "节目", order: 0, episodes: values }] : [] };
  }
  const groups = [];
  for (let start = 0; start < values.length; start += 1e3) {
    const episodes = values.slice(start, start + 1e3).map((value, order) => ({ ...value, order }));
    groups.push({ id: "range:" + episodes[0].id, title: `第 ${start + 1}-${start + episodes.length} 集`, order: groups.length, episodes });
  }
  if (groups.length > 128) throw new Error("Chapter group limit exceeded.");
  if (request.groupId !== void 0) {
    const selected = groups.find((g) => g.id === request.groupId);
    if (!selected) throw new Error("Requested chapter group is unavailable.");
    return { items: selected.episodes, groups: [{ ...selected, order: 0 }] };
  }
  if (request.supportsDeferredGroups !== true) throw new Error("Large catalog requires deferred group support.");
  return { items: groups[0].episodes, groups: groups.map((g, index) => index === 0 ? g : { ...g, episodes: [], deferred: true }) };
}
function media(chapterId, upstream, title = null) {
  const url = safeUrl(upstream, "audio");
  if (!url) ctx().errors.raise("source_media_resolution_failed");
  const headers = { Referer: referer };
  return {
    chapterId,
    contentKind: "audio",
    title: nullable(title),
    updatedAt: null,
    text: null,
    pages: [],
    media: { url: ctx().resource.proxy({ kind: "audio", url, headers }), resourceType: "audio", resourcePolicy: "sessionOnly", expiresAt: null, mimeType: null, headers }
  };
}

// src/discovery.mts
var channels = [
  ["hot", "热门榜", "rank?section=hot"],
  ["new", "最新上架", "rank?section=new"],
  ["novel", "全部有声小说", "category?category=2"],
  ["fantasy", "玄幻奇幻", "category?category=2&type=46"],
  ["wuxia", "武侠小说", "category?category=2&type=11"],
  ["suspense", "恐怖惊悚", "category?category=2&type=14"],
  ["history", "历史军事", "category?category=2&type=15"],
  ["drama", "广播剧", "category?category=2&type=36"],
  ["storytelling", "全部评书", "category?category=1"],
  ["shan", "单田芳", "category?category=1&type=1"],
  ["liu", "刘兰芳", "category?category=1&type=2"],
  ["tian", "田连元", "category?category=1&type=3"],
  ["yuan", "袁阔成", "category?category=1&type=4"]
];
async function discover(request) {
  if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null) throw new Error("Invalid discovery root request.");
    const components = [
      { type: "searchInput", id: "source-search", label: "搜索有声专辑", placeholder: "输入书名、作者或演播者", submitLabel: "搜索" },
      { type: "section", id: "channels", title: "榜单与分类", subtitle: null, icon: "audio", children: [
        { type: "categoryCollection", id: "channel-list", layout: "chips", categories: channels.map(([id, title]) => ({ id, title, target: "channel:" + id, count: null, url: null, icon: "audio" })) }
      ] }
    ];
    for (const id of ["hot", "new"]) {
      const result2 = await discover({ target: "channel:" + id, cursor: null, collectionId: null, pageSize: Math.min(6, request.pageSize) });
      if (result2.kind === "document") components.push(...result2.document.components);
    }
    return { kind: "document", document: { components } };
  }
  const channel = channels.find(([id]) => request.target === "channel:" + id);
  if (!channel) throw new Error("Invalid discovery target.");
  const collectionId = request.target;
  if (request.collectionId !== null && request.collectionId !== collectionId) throw new Error("Invalid collection ID.");
  const { page } = position(request.cursor, request.target), data = await json(channel[2] + "&page=" + page);
  const raw = records(data.items ?? data.data), pages = natural(data.pages);
  const more = typeof data.has_more === "boolean" ? data.has_more : pages !== null && page < pages;
  const result = window(summaries(raw), request.target, request.cursor, request.pageSize, more && raw.length > 0);
  const items = result.items.map((content) => ({ content, rank: null, metric: null, recommendation: null }));
  const continuation = result.nextCursor === null ? null : { target: request.target, cursor: result.nextCursor };
  if (request.collectionId !== null) return { kind: "append", collectionId, items, continuation };
  return { kind: "document", document: { components: [{ type: "section", id: collectionId + ":section", title: channel[1], subtitle: null, icon: "audio", children: [
    { type: "contentCollection", id: collectionId, layout: "coverGrid", items, continuation }
  ] }] } };
}

// src/index.mts
var deferredGroups = true;
var ty = "https://api.365ting.com";
function activate(context2) {
  initialize(context2, "https://fmfm.tingyou.fm/listening-api/", "https://fmfm.tingyou.fm/");
}
async function searchPage(query, page) {
  const result = await jsonUrl(ty + "/tingyou-app/search?keyword=" + encodeURIComponent(query) + "&page=" + page);
  if (!object(result.data) || !Array.isArray(result.data.items)) throw new Error("Invalid ten-audio search response.");
  return result.data;
}
async function search(request) {
  const query = request.query.trim(), scope = "search:" + query;
  if (!query) return { items: [], nextCursor: null, totalCount: 0 };
  const { page } = position(request.cursor, scope);
  if (page % 2 !== 1) throw new Error("Invalid search batch cursor.");
  const primary = await Promise.allSettled([searchPage(query, page), searchPage(query, page + 1)]);
  const map = /* @__PURE__ */ new Map();
  for (const result of primary) if (result.status === "fulfilled") for (const item of records(result.value.items)) {
    const id = text(item.book_id ?? item.id);
    if (!/^\d{1,20}$/u.test(id)) continue;
    if (!map.has(id) || Number(item.album_id) > 0 && !(Number(map.get(id).album_id) > 0)) map.set(id, item);
  }
  const lastPrimary = primary[1];
  let more = lastPrimary.status === "fulfilled" ? lastPrimary.value.has_more === true : primary[0]?.status === "fulfilled" && primary[0].value.has_more === true;
  if (map.size < 5 || primary.some((r) => r.status === "rejected")) {
    const fallback = await Promise.allSettled([json("search", { keyword: query, page }), json("search", { keyword: query, page: page + 1 })]);
    const completed = [...primary, ...fallback].filter((r) => r.status === "fulfilled");
    if (completed.length === 0) throw new Error("Both audio search providers failed.");
    for (const result of fallback) if (result.status === "fulfilled") {
      if (!Array.isArray(result.value.results)) throw new Error("Invalid fallback search response.");
      for (const item of records(result.value.results)) {
        const id = text(item.id);
        if (/^\d{1,20}$/u.test(id) && !map.has(id)) map.set(id, item);
      }
    }
    const lastFallback = fallback[1];
    more ||= lastFallback.status === "fulfilled" ? lastFallback.value.has_more === true : fallback[0]?.status === "fulfilled" && fallback[0].value.has_more === true;
    for (let i = 0; i < 2; i++) if (primary[i].status === "rejected" && fallback[i].status === "rejected") throw new Error("Audio search page is unavailable.");
  }
  const score = (item) => {
    const title = text(item.title).toLowerCase(), q = query.toLowerCase();
    return title === q ? 3 : title.startsWith(q) ? 2 : title.includes(q) ? 1 : 0;
  };
  const values = [...map.values()].sort((a, b) => score(b) - score(a) || Number(Number(b.album_id) > 0) - Number(Number(a.album_id) > 0));
  return { ...window(summaries(values), scope, request.cursor, request.pageSize, more && values.length > 0, 2), totalCount: null };
}
async function searchSuggestions() {
  return { items: [], nextCursor: null };
}
async function lookup(id, refresh = false) {
  return snapshot("lookup:" + id, async () => {
    const data = await searchPage(id, 1);
    return records(data.items).find((item) => text(item.book_id ?? item.id) === id) ?? null;
  }, refresh);
}
async function localTracks(id, refresh = false) {
  return snapshot("local-catalog:" + id, async () => {
    const metadata = await lookup(id, refresh);
    if (!metadata || !(Number(metadata.album_id) > 0)) return null;
    const data = await jsonUrl(ty + "/api/albums/" + native(metadata.album_id) + "/tracks?user_id=-1");
    if (!Array.isArray(data.data)) throw new Error("Invalid ten-audio catalog.");
    const tracks = records(data.data).map((value) => ({
      id: value.id,
      title: value.title,
      duration: value.duration,
      track_no: value.track_no,
      is_locked: value.is_locked,
      locked: value.locked,
      is_vip: value.is_vip
    }));
    const total = natural(data.total);
    if (total !== null && tracks.length !== total) throw new Error("Incomplete ten-audio catalog.");
    chapters(id, tracks, "track");
    if (tracks.every((v) => natural(v.track_no) !== null) && new Set(tracks.map((v) => Number(v.track_no))).size === tracks.length) tracks.sort((a, b) => Number(a.track_no) - Number(b.track_no));
    return tracks;
  }, refresh);
}
async function getDetail(request) {
  const id = album(request.id);
  let catalogUrl = "https://fmfm.tingyou.fm/listening-api/chapters/" + id;
  let data;
  try {
    data = await json("album/" + id);
    if (native(data.id) !== id || data.available === false) throw new Error("Album is unavailable.");
  } catch {
    const local = await lookup(id);
    if (!local || !(Number(local.album_id) > 0)) throw new Error("Album detail is unavailable.");
    data = local;
    catalogUrl = ty + "/api/albums/" + native(local.album_id) + "/tracks?user_id=-1";
  }
  return { ...summary(data), aliases: [], catalogUrl };
}
async function getChapters(request) {
  const id = album(request.id);
  if (request.groupId?.startsWith("range:chapter:" + id + ":")) return catalogResult(request, chapters(id, await remoteChapters(id, request.refresh), "chapter"));
  if (request.groupId?.startsWith("range:track:" + id + ":")) {
    const tracks2 = await localTracks(id, request.refresh);
    if (!tracks2?.length) throw new Error("Ten-audio group is unavailable.");
    return catalogResult(request, chapters(id, tracks2, "track"));
  }
  let tracks = null;
  try {
    tracks = await localTracks(id, request.refresh);
  } catch {
    ctx().log.warn("local_catalog_unavailable");
  }
  if (tracks?.length) return catalogResult(request, chapters(id, tracks, "track"));
  return catalogResult(request, chapters(id, await remoteChapters(id, request.refresh), "chapter"));
}
async function getContent(request) {
  const id = album(request.id), match = new RegExp("^(chapter|track):" + id + ":(\\d{1,20})$", "u").exec(request.chapterId);
  if (!match) throw new Error("Invalid chapter ID.");
  if (match[1] === "track") {
    const values2 = await localTracks(id), item2 = values2?.find((v) => String(v.id) === match[2]);
    if (!item2) throw new Error("Ten-audio track is unavailable.");
    if (item2.is_locked === true || item2.locked === true || item2.is_vip === true) ctx().errors.raise("source_access_blocked");
    const upstream = ty + "/api/audio/" + native(item2.id);
    if (await localAudioAvailable(upstream)) return media(request.chapterId, upstream, item2.title);
    const remote = await remoteChapters(id), trackNo = natural(item2.track_no);
    const matches = remote.filter((v) => text(v.title) === text(item2.title) && (trackNo === null || natural(v.index) === trackNo));
    if (matches.length !== 1) ctx().errors.raise("source_media_resolution_failed");
    const fallback = matches[0];
    if (fallback.is_locked === true || fallback.locked === true || fallback.is_vip === true) ctx().errors.raise("source_access_blocked");
    const data2 = await json("play", { album_id: id, chapter_idx: natural(fallback.index) });
    ctx().log.warn("local_audio_unavailable_using_matched_chapter");
    return media(request.chapterId, data2.play_url, item2.title);
  }
  const values = await remoteChapters(id), item = values.find((v) => String(v.id) === match[2]);
  if (!item || natural(item.index) === null) throw new Error("Chapter is unavailable.");
  if (item.is_locked === true || item.locked === true || item.is_vip === true) ctx().errors.raise("source_access_blocked");
  const data = await json("play", { album_id: id, chapter_idx: natural(item.index) });
  return media(request.chapterId, data.play_url, item.title);
}
async function localAudioAvailable(url) {
  try {
    const response = await ctx().http.fetch(url, { method: "HEAD", headers: { Referer: "https://fmfm.tingyou.fm/" }, signal: AbortSignal.timeout(8e3) });
    await response.body?.cancel();
    return response.ok || response.status === 405 || response.status === 501;
  } catch {
    return false;
  }
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
