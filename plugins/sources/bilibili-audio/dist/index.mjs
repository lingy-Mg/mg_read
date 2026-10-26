import { createRequire as __mgreadCreateRequire } from 'node:module'; const require = __mgreadCreateRequire(import.meta.url);

// src/index.mts
var api = "https://api.bilibili.com";
var site = "https://www.bilibili.com";
var userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/136.0.0.0 Safari/537.36";
var requestHeaders = Object.freeze({ Accept: "application/json, text/plain, */*", "Accept-Language": "zh-CN,zh;q=0.9", Referer: `${site}/`, "User-Agent": userAgent });
var context;
var views = /* @__PURE__ */ new Map();
async function activate(next) {
  context = next;
  views.clear();
  next.log.info("source_activated");
}
async function discover(request) {
  if (request.target !== null || request.cursor !== null || request.collectionId !== null) throw new Error("Discovery is not supported.");
  return frozen({ kind: "document", document: { components: [{
    type: "section",
    id: "audio-links",
    title: "B站链接听书",
    subtitle: "粘贴视频链接、分享文本或 BV 号，读取后选择分 P 播放音频。",
    icon: "audio",
    children: [{
      type: "searchInput",
      id: "video-link",
      label: "B站视频链接或 BV 号",
      placeholder: "https://www.bilibili.com/video/BV… 或 b23.tv 短链接",
      submitLabel: "读取音频"
    }]
  }] } });
}
async function search(request) {
  const query = request.query.trim();
  if (query === "") return frozen({ items: [], nextCursor: null, totalCount: 0 });
  const bvid = await inputBvid(query);
  if (bvid !== null) {
    const detail = await getDetail({ id: `bvid:${bvid}` });
    return frozen({ items: [detail], nextCursor: null, totalCount: 1 });
  }
  const page = cursorPage(request.cursor);
  const limit = clamp(request.pageSize);
  const json = await fetchJson(`${api}/x/web-interface/search/type?${new URLSearchParams({ search_type: "video", keyword: query, page: String(page) })}`);
  const data = asObject(json.data);
  const results = Array.isArray(data.result) ? data.result : [];
  const items = results.filter(isObject).map((entry) => {
    const bvid2 = validBvid(text(entry.bvid));
    if (bvid2 === null) return null;
    return summary({
      bvid: bvid2,
      title: stripHtml(text(entry.title)) || `视频 ${bvid2}`,
      author: text(entry.author) || null,
      cover: text(entry.pic),
      description: stripHtml(text(entry.description)) || null,
      duration: parseDuration(text(entry.duration))
    });
  }).filter((item) => item !== null).slice(0, limit);
  return frozen({ items, nextCursor: results.length >= limit ? `search:${page + 1}` : null, totalCount: numberOrNull(data.numResults) });
}
async function searchSuggestions(_request) {
  return frozen({ items: [], nextCursor: null });
}
async function getDetail(request) {
  const bvid = contentBvid(request.id);
  const data = await view(bvid);
  const item = summary({
    bvid,
    title: text(data.title) || `视频 ${bvid}`,
    author: text(asObject(data.owner).name) || null,
    cover: text(data.pic),
    description: text(data.desc) || null,
    duration: numberOrNull(data.duration)
  });
  return frozen({ ...item, description: text(data.desc) || null, aliases: [], catalogUrl: item.url });
}
async function getChapters(request) {
  const bvid = contentBvid(request.id);
  const data = await view(bvid);
  const pages = Array.isArray(data.pages) ? data.pages.filter(isObject) : [];
  const items = pages.map((page, index) => {
    const cid = text(page.cid);
    if (cid === "") return null;
    const pageNumber = numberOrNull(page.page) ?? index + 1;
    const title = text(page.part) || `P${pageNumber}`;
    return frozen({
      id: episodeId(bvid, cid),
      title,
      order: index,
      url: `${site}/video/${bvid}/?p=${pageNumber}`,
      volumeTitle: "音频选集",
      wordCount: null,
      updatedAt: null,
      isLocked: null,
      attributes: durationAttribute(page.duration)
    });
  }).filter((item) => item !== null);
  const groups = items.length === 0 ? [] : [frozen({ id: `group:${bvid}:pages`, title: "视频选集", order: 0, episodes: items })];
  return frozen({ items, groups });
}
async function getContent(request) {
  const bvid = contentBvid(request.id);
  const cid = episodeCid(request.chapterId, bvid);
  const params = new URLSearchParams({ bvid, cid, qn: "80", fnval: "16", fourk: "1" });
  const data = await fetchJson(`${api}/x/player/playurl?${params}`);
  const payload = asObject(data.data);
  const dash = asObject(payload.dash);
  const tracks = (Array.isArray(dash.audio) ? dash.audio.filter(isObject) : []).filter((track) => text(track.codecs).startsWith("mp4a.") && safeHttpUrl(text(track.baseUrl || track.base_url))).sort((left, right) => (numberOrNull(right.bandwidth) ?? 0) - (numberOrNull(left.bandwidth) ?? 0));
  const upstream = text(tracks[0]?.baseUrl || tracks[0]?.base_url);
  if (!safeHttpUrl(upstream)) return requireContext().errors.raise({
    code: "source_media_resolution_failed",
    message: "B站未返回可播放的独立音轨。",
    annotation: "请确认视频公开可用后重试。"
  });
  const headers = { Referer: `${site}/video/${bvid}/`, "User-Agent": userAgent };
  return frozen({
    chapterId: request.chapterId,
    contentKind: "audio",
    title: null,
    updatedAt: null,
    text: null,
    pages: [],
    media: {
      url: requireContext().resource.proxy({ kind: "audio", url: upstream, headers }),
      resourceType: "audio",
      resourcePolicy: "sessionOnly",
      expiresAt: null,
      mimeType: "audio/mp4",
      headers
    }
  });
}
async function view(bvid) {
  const cached = views.get(bvid);
  if (cached !== void 0 && cached.expires > Date.now()) return cached.value;
  if (views.size >= 16) views.delete(views.keys().next().value);
  const value = fetchJson(`${api}/x/web-interface/view?bvid=${encodeURIComponent(bvid)}`).then((response) => {
    const data = asObject(response.data);
    if (text(data.bvid) !== bvid) throw new Error("B站返回的视频与输入不一致。");
    return data;
  });
  const entry = { expires: Date.now() + 6e4, value };
  views.set(bvid, entry);
  try {
    return await value;
  } catch (error) {
    if (views.get(bvid) === entry) views.delete(bvid);
    throw error;
  }
}
async function fetchJson(url) {
  const response = await requireContext().http.fetch(url, { headers: requestHeaders });
  if (!response.ok) {
    if ([403, 412, 429].includes(response.status)) blocked(`B站请求被拒绝（HTTP ${response.status}）。`);
    throw new Error(`B站请求失败（HTTP ${response.status}）。`);
  }
  const payload = await response.json();
  const root = asObject(payload);
  if ([-352, -412].includes(Number(root.code))) blocked(`B站访问受限（${root.code}）。`);
  if (Number(root.code) !== 0) throw new Error(`B站未返回视频数据：${text(root.message) || text(root.code)}。`);
  return root;
}
function blocked(message) {
  return requireContext().errors.raise({ code: "source_access_blocked", message, annotation: "请稍后重试；这不表示数据源未安装。" });
}
async function inputBvid(input) {
  const direct = /(?<![A-Za-z0-9])BV[1-9A-HJ-NP-Za-km-z]{10}(?![A-Za-z0-9])/u.exec(input)?.[0];
  if (direct !== void 0) return direct;
  const short = /https?:\/\/b23\.tv\/[A-Za-z0-9]+/u.exec(input)?.[0];
  if (short !== void 0) {
    const response = await requireContext().http.fetch(short, { headers: requestHeaders });
    if ([403, 412, 429].includes(response.status)) blocked(`B站短链接请求被拒绝（HTTP ${response.status}）。`);
    const target = new URL(response.url || short);
    const match = /^\/video\/(BV[1-9A-HJ-NP-Za-km-z]{10})(?:\/|$)/u.exec(target.pathname);
    if (response.ok && (target.hostname === "www.bilibili.com" || target.hostname === "bilibili.com") && match?.[1]) return match[1];
    throw new Error("无法解析 B站短链接，请使用完整视频链接或 BV 号。");
  }
  if (/bilibili\.com|b23\.tv|^BV/u.test(input)) throw new Error("请输入有效的 B站视频链接或 BV 号。");
  return null;
}
function summary(value) {
  return frozen({
    id: `bvid:${value.bvid}`,
    title: value.title,
    contentKind: "audio",
    coverOrientation: "landscape",
    author: value.author,
    url: `${site}/video/${value.bvid}/`,
    coverUrl: proxyImage(value.cover),
    description: value.description,
    language: "zh-CN",
    status: "unknown",
    access: "unknown",
    wordCount: null,
    chapterCount: null,
    publishedAt: null,
    updatedAt: null,
    latestChapter: null,
    categories: [],
    tags: [],
    attributes: durationAttribute(value.duration)
  });
}
function proxyImage(value) {
  if (value === "") return null;
  const url = absoluteHttpUrl(value.startsWith("//") ? `https:${value}` : value);
  return url === null ? null : requireContext().resource.proxy({ kind: "image", url, headers: { Referer: `${site}/` } });
}
function contentBvid(id) {
  const match = /^bvid:(BV[1-9A-HJ-NP-Za-km-z]{10})$/u.exec(id);
  if (match?.[1] === void 0) throw new Error("Video ID is invalid.");
  return match[1];
}
function episodeId(bvid, cid) {
  return `bvid:${bvid}:cid:${cid}`;
}
function episodeCid(id, bvid) {
  const match = new RegExp(`^bvid:${bvid}:cid:(\\d+)$`, "u").exec(id);
  if (match?.[1] === void 0) throw new Error("Episode ID is invalid.");
  return match[1];
}
function validBvid(value) {
  return /^BV[1-9A-HJ-NP-Za-km-z]{10}$/u.test(value) ? value : null;
}
function cursorPage(cursor) {
  if (cursor === null) return 1;
  const page = Number(cursor.startsWith("search:") ? cursor.slice(7) : NaN);
  if (!Number.isSafeInteger(page) || page < 2 || page > 1e3) throw new Error("Cursor is invalid.");
  return page;
}
function clamp(value) {
  return Math.max(1, Math.min(50, Math.floor(value)));
}
function durationAttribute(value) {
  const duration = numberOrNull(value);
  return duration === null ? [] : [{ key: "durationSeconds", label: "时长（秒）", value: String(duration) }];
}
function parseDuration(value) {
  const parts = value.split(":").map(Number);
  if (parts.some((part) => !Number.isFinite(part))) return null;
  return parts.reduce((total, part) => total * 60 + part, 0);
}
function stripHtml(value) {
  return decodeHtml(value.replace(/<[^>]*>/gu, "").replace(/\s+/gu, " ")).trim();
}
function decodeHtml(value) {
  return value.replace(/&amp;/giu, "&").replace(/&quot;/giu, '"').replace(/&#39;/giu, "'").replace(/&lt;/giu, "<").replace(/&gt;/giu, ">").replace(/&nbsp;/giu, " ");
}
function absoluteHttpUrl(value) {
  return safeHttpUrl(value) ? new URL(value).toString() : null;
}
function safeHttpUrl(value) {
  try {
    const url = new URL(value);
    return (url.protocol === "https:" || url.protocol === "http:") && url.username === "" && url.password === "";
  } catch {
    return false;
  }
}
function text(value) {
  return typeof value === "string" ? value.trim() : typeof value === "number" ? String(value) : "";
}
function numberOrNull(value) {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}
function asObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value) ? value : {};
}
function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
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
