/* zhi35/iptv icon attribution:
MIT License

Copyright (c) 2024 Amazing Watermelon

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/
import { createRequire as __mgreadCreateRequire } from 'node:module'; const require = __mgreadCreateRequire(import.meta.url);

// src/playlist.mts
import { createHash } from "node:crypto";
var volatileParameter = /^(?:_+|token|access_token|auth|auth_key|authkey|sign|signature|sig|expires?|expiration|timestamp|ts|t|session|sessionid|livekey|playkey|accountinfo|guardenctype|wssecret|wstime|txsecret|txtime|hdnts)$/iu;
function digest(value) {
  return createHash("sha256").update(value).digest("hex").slice(0, 24);
}
function safeHttpUrl(value) {
  if (value.length > 8192 || /[\u0000-\u0020\u007f]/u.test(value)) return null;
  try {
    const url = new URL(value);
    if (!["http:", "https:"].includes(url.protocol) || url.username || url.password) return null;
    const host = url.hostname.toLowerCase().replace(/^\[|\]$/gu, "");
    if (!host.includes(".") && !host.includes(":")) return null;
    if (host === "localhost" || /\.(?:localhost|local|internal)$/u.test(host)) return null;
    if (/^(?:0|10|127)\.|^169\.254\.|^192\.168\.|^172\.(?:1[6-9]|2\d|3[01])\./u.test(host)) return null;
    if (host.includes(":") && !/^[23][\da-f]{0,3}:/iu.test(host)) return null;
    url.hash = "";
    return url.href;
  } catch {
    return null;
  }
}
function resourceKey(value) {
  const url = new URL(value);
  for (const key of [...url.searchParams.keys()]) {
    if (volatileParameter.test(key)) url.searchParams.delete(key);
  }
  url.searchParams.sort();
  return url.href;
}
function parsePlaylist(text) {
  const channels = /* @__PURE__ */ new Map();
  let pending = null;
  for (const raw of text.replace(/^\uFEFF/u, "").split(/\r?\n/u)) {
    const line = raw.trim();
    if (line.startsWith("#EXTINF:")) {
      pending = parseEntry(line);
      continue;
    }
    if (!line || line.startsWith("#")) continue;
    const entry = pending;
    pending = null;
    const url = safeHttpUrl(line);
    if (entry === null || url === null) continue;
    const stableResource = resourceKey(url);
    const id = `channel:${digest(entry.epgId === null ? `resource:${stableResource}` : `tvg-id:${entry.epgId}`)}`;
    let channel = channels.get(id);
    if (channel === void 0) {
      channel = { id, title: entry.title, name: entry.name, cover: entry.cover, categories: [], streams: [] };
      channels.set(id, channel);
    }
    if (!channel.categories.includes(entry.group)) channel.categories.push(entry.group);
    channel.cover ??= entry.cover;
    const streamId = `stream:${digest(stableResource)}`;
    const existing = channel.streams.findIndex((stream2) => stream2.id === streamId);
    const stream = { id: streamId, url, ipv6: new URL(url).hostname.startsWith("[") };
    if (existing < 0) channel.streams.push(stream);
    else channel.streams[existing] = stream;
    if (channels.size > 5e3 || channel.streams.length > 64) throw new Error("IPTV 播放列表超出大小限制。");
  }
  const result = [...channels.values()];
  if (result.length === 0) throw new Error("IPTV 播放列表中没有有效频道。");
  const revision = digest(JSON.stringify(result.map(({ id, title, name, categories }) => [id, title, name, categories])));
  return { channels: result, revision };
}
function parseEntry(line) {
  let quote = "";
  let comma = -1;
  for (let index = 8; index < line.length; index += 1) {
    const char = line[index];
    if (quote) {
      if (char === quote) quote = "";
    } else if (char === '"' || char === "'") quote = char;
    else if (char === ",") {
      comma = index;
      break;
    }
  }
  if (comma < 0) return null;
  const attributes = {};
  const metadata = line.slice(8, comma);
  for (const match of metadata.matchAll(/([\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s]+))/gu)) {
    attributes[match[1].toLowerCase()] = (match[2] ?? match[3] ?? match[4] ?? "").trim();
  }
  const title = line.slice(comma + 1).trim() || attributes["tvg-name"] || "";
  if (!title || title.length > 256) return null;
  const group = attributes["group-title"] || "未分组";
  if (group.length > 256) return null;
  return {
    title,
    name: attributes["tvg-name"] && attributes["tvg-name"].length <= 256 ? attributes["tvg-name"] : null,
    epgId: attributes["tvg-id"] || null,
    cover: safeHttpUrl(attributes["tvg-logo"] ?? ""),
    group
  };
}

// src/store.mts
var playlistUrls = [
  "https://live.zhi35.com/iptv.m3u",
  "https://raw.githubusercontent.com/zhi35/iptv/master/iptv.m3u"
];
var maximumBytes = 2 * 1024 * 1024;
function createPlaylistStore(context, now = Date.now) {
  let cached;
  let pending;
  return { load };
  async function load(refresh = false) {
    if (!refresh && cached !== void 0 && now() - cached.time < 5 * 6e4) return cached.playlist;
    if (pending !== void 0) return pending;
    const current = fetchPlaylist().catch((error) => {
      if (cached !== void 0 && now() - cached.time < 24 * 60 * 6e4) {
        context.log.warn("iptv_playlist_stale");
        return cached.playlist;
      }
      throw error;
    });
    pending = current;
    try {
      return await current;
    } finally {
      if (pending === current) pending = void 0;
    }
  }
  async function fetchPlaylist() {
    for (let index = 0; index < playlistUrls.length; index += 1) {
      try {
        const response = await context.http.fetch(playlistUrls[index], {
          headers: { Accept: "application/vnd.apple.mpegurl,audio/x-mpegurl,text/plain,*/*" },
          signal: AbortSignal.timeout(12e3)
        });
        if (!response.ok) {
          await response.body?.cancel();
          throw new Error("playlist_http_failed");
        }
        const playlist = parsePlaylist(await readBoundedText(response));
        cached = { playlist, time: now() };
        context.log.info(`iptv_playlist_loaded channels=${playlist.channels.length} endpoint=${index + 1}`);
        return playlist;
      } catch {
        context.log.warn(`iptv_playlist_request_failed endpoint=${index + 1}`);
      }
    }
    throw new Error("IPTV 播放列表暂时无法获取，请稍后重试。");
  }
}
async function readBoundedText(response) {
  if (Number(response.headers.get("content-length")) > maximumBytes) {
    await response.body?.cancel();
    throw new Error("playlist_too_large");
  }
  if (response.body === null) throw new Error("playlist_empty");
  const reader = response.body.getReader();
  const chunks = [];
  let size = 0;
  try {
    while (true) {
      const chunk = await reader.read();
      if (chunk.done) break;
      size += chunk.value.byteLength;
      if (size > maximumBytes) throw new Error("playlist_too_large");
      chunks.push(chunk.value);
    }
    return Buffer.concat(chunks).toString("utf8");
  } finally {
    await reader.cancel().catch(() => {
    });
    reader.releaseLock();
  }
}

// src/media.mts
async function resolveMedia(context, url, title = "该频道") {
  const path = new URL(url).pathname;
  if (/\.m3u8?$/iu.test(path)) return inspectHls(context, url, title);
  if (/\.flv$/iu.test(path)) return { url, resourceType: "video", mimeType: "video/x-flv" };
  if (/\.mp4$/iu.test(path)) return { url, resourceType: "video", mimeType: "video/mp4" };
  const response = await context.http.fetch(url, {
    headers: { Accept: "*/*", Range: "bytes=0-1023" },
    signal: AbortSignal.timeout(1e4)
  });
  const finalUrl = safeHttpUrl(response.url || url);
  const reader = response.body?.getReader();
  try {
    if (!response.ok || reader === void 0 || finalUrl === null) throw new Error("直播线路暂时无法解析。");
    const chunks = [];
    let size = 0;
    while (size < 1024) {
      const chunk = await reader.read();
      if (chunk.done) break;
      const prefix = chunk.value.subarray(0, 1024 - size);
      chunks.push(prefix);
      size += prefix.byteLength;
      if (size >= 8) break;
    }
    const bytes = Buffer.concat(chunks);
    if (bytes.toString("utf8").replace(/^\uFEFF/u, "").trimStart().startsWith("#EXTM3U")) {
      return { url: finalUrl, resourceType: "hls", mimeType: "application/vnd.apple.mpegurl" };
    }
    if (bytes.subarray(0, 3).toString("ascii") === "FLV") return { url: finalUrl, resourceType: "video", mimeType: "video/x-flv" };
    if (bytes.subarray(4, 8).toString("ascii") === "ftyp") return { url: finalUrl, resourceType: "video", mimeType: "video/mp4" };
    const mime = (response.headers.get("content-type") ?? "").split(";")[0].trim().toLowerCase();
    if (bytes.length > 0 && /^video\//u.test(mime)) return { url: finalUrl, resourceType: "video", mimeType: mime };
    throw new Error("直播线路没有返回可识别的视频或 HLS。");
  } finally {
    if (reader !== void 0) {
      await reader.cancel().catch(() => {
      });
      reader.releaseLock();
    }
  }
}
async function inspectHls(context, url, title) {
  let response;
  try {
    response = await context.http.fetch(url, {
      headers: { Accept: "application/vnd.apple.mpegurl,application/x-mpegurl,text/plain,*/*" },
      signal: AbortSignal.timeout(8e3)
    });
  } catch {
    return failHls(context, url, title, "直播服务器连接失败或超时。");
  }
  if (!response.ok) {
    await response.body?.cancel().catch(() => {
    });
    return failHls(context, url, title, `直播地址请求失败（HTTP ${response.status}）。`, [401, 403, 451].includes(response.status));
  }
  if (safeHttpUrl(response.url || url) === null || response.body === null) {
    await response.body?.cancel().catch(() => {
    });
    return failHls(context, url, title, "直播服务器没有提供有效清单。");
  }
  const reader = response.body.getReader();
  const chunks = [];
  let size = 0;
  let valid = false;
  try {
    while (size < 8192) {
      const chunk = await reader.read();
      if (chunk.done) break;
      const part = chunk.value.subarray(0, 8192 - size);
      chunks.push(part);
      size += part.byteLength;
      const text = Buffer.concat(chunks).toString("utf8").replace(/^\uFEFF/u, "").trimStart();
      if (text.includes("\n") && text.split(/\r?\n/u)[0]?.trim() !== "#EXTM3U") break;
      if (/^#EXTM3U\r?\n/u.test(text) && /^#EXT-X-(?:TARGETDURATION|STREAM-INF):/mu.test(text)) {
        valid = true;
        break;
      }
    }
  } catch {
    return failHls(context, url, title, "直播清单读取失败或超时。");
  } finally {
    await reader.cancel().catch(() => {
    });
    reader.releaseLock();
  }
  if (!valid) return failHls(context, url, title, "直播地址没有返回有效的 HLS 清单。");
  return { url, resourceType: "hls", mimeType: "application/vnd.apple.mpegurl" };
}
function failHls(context, url, title, reason, blocked = false) {
  return context.errors.raise({
    code: blocked ? "source_access_blocked" : "source_media_resolution_failed",
    message: `${title}：${reason}`,
    annotation: `${new URL(url).hostname.startsWith("[") ? "这条上游线路使用 IPv6。" : ""}当前直播尚未成功打开；请更换有效线路，或等待上游更新。`
  });
}

// src/logos.mts
var catalogUrl = "https://upload.112114.xyz/logo/";
var day = 24 * 60 * 6e4;
var maximumCatalogBytes = 3 * 1024 * 1024;
function canonicalLogoUrl(value) {
  const safe = safeHttpUrl(value);
  if (safe === null) return null;
  const url = new URL(safe);
  if (["live.fanmingming.cn", "live.fanmingming.com"].includes(url.hostname) && /^\/tv\/[^/]+\.png$/iu.test(url.pathname)) {
    return `https://raw.githubusercontent.com/fanmingming/live/main${url.pathname}`;
  }
  if (url.hostname !== "ghproxy.zhi35.com" && url.hostname !== "ghp.ci") return safe;
  const embedded = url.pathname.slice(1).replace(/^raw\.githubusercontent\.com\//u, "https://raw.githubusercontent.com/");
  const upstream = safeHttpUrl(embedded);
  if (upstream === null) return null;
  const raw = new URL(upstream);
  if (raw.origin === "https://raw.githubusercontent.com" && raw.pathname === "/wanglindl/TVlogo/main/img/CTI3.pngg") {
    raw.pathname = "/wanglindl/TVlogo/main/img/CTI3.png";
  }
  if (raw.origin !== "https://raw.githubusercontent.com" || !/^\/(?:wanglindl\/TVlogo\/main\/img|suxuang\/myIPTV\/main\/tvlog)\/[^/]+\.png$/iu.test(raw.pathname)) return null;
  return raw.href;
}
function parseLogoCatalog(html) {
  const result = /* @__PURE__ */ new Map();
  for (const match of html.matchAll(/href\s*=\s*["']([^"']+\.png)["']/giu)) {
    try {
      const url = new URL(match[1].replaceAll("&amp;", "&"), catalogUrl);
      if (url.origin !== new URL(catalogUrl).origin || !url.pathname.startsWith("/logo/") || url.search || url.hash) continue;
      const filename = decodeURIComponent(url.pathname.slice("/logo/".length));
      if (!filename || filename.length > 256 || /[\u0000-\u001f\u007f/\\]/u.test(filename) || !/\.png$/iu.test(filename)) continue;
      result.set(filename, url.href);
      if (result.size > 2e4) throw new Error("logo_catalog_too_many_entries");
    } catch (error) {
      if (error instanceof Error && error.message === "logo_catalog_too_many_entries") throw error;
    }
  }
  if (result.size === 0) throw new Error("logo_catalog_empty");
  return result;
}
function createLogoResolver(context, now = Date.now) {
  const cache = /* @__PURE__ */ new Map();
  const pending = /* @__PURE__ */ new Map();
  let catalog;
  let catalogExpires = 0;
  let catalogPending;
  let running = 0;
  const waiting = [];
  return { prepare };
  async function prepare(channels) {
    return Promise.all(channels.map(async (channel) => ({ ...channel, cover: await resolve(channel.cover) })));
  }
  async function resolve(cover) {
    if (cover === null) return null;
    const canonical = canonicalLogoUrl(cover);
    if (canonical === null) return null;
    const url = new URL(canonical);
    if (url.hostname !== "tb.zbds.top" || !/^\/logo\/[^/]+\.png$/iu.test(url.pathname)) return canonical;
    const cached = cache.get(canonical);
    if (cached !== void 0 && cached.expires > now()) return cached.url;
    const existing = pending.get(canonical);
    if (existing !== void 0) return existing;
    const current = limited(() => repairLocalLogo(canonical));
    pending.set(canonical, current);
    try {
      return await current;
    } finally {
      if (pending.get(canonical) === current) pending.delete(canonical);
    }
  }
  async function limited(action) {
    if (running >= 4) await new Promise((done) => waiting.push(done));
    else running += 1;
    try {
      return await action();
    } finally {
      const next = waiting.shift();
      if (next !== void 0) next();
      else running -= 1;
    }
  }
  function remember(key, value, ttl) {
    cache.delete(key);
    cache.set(key, { url: value, expires: now() + ttl });
    while (cache.size > 512) cache.delete(cache.keys().next().value);
    return value;
  }
  async function inspect(url) {
    try {
      const response = await context.http.fetch(url, { method: "HEAD", headers: { Accept: "image/*" }, signal: AbortSignal.timeout(4e3) });
      await response.body?.cancel();
      const mime = (response.headers.get("content-type") ?? "").toLowerCase();
      if (response.ok && /^image\/(?:png|jpeg|gif|webp)(?:;|$)/u.test(mime)) return "image";
      if (response.status === 404 || response.status === 410 || response.ok && /^text\/html/u.test(mime)) return "missing";
    } catch {
      context.log.warn("iptv_logo_probe_unavailable");
    }
    return "unknown";
  }
  async function repairLocalLogo(original) {
    const state = await inspect(original);
    if (state === "image") return remember(original, original, day);
    if (state === "unknown") return remember(original, original, 6e4);
    const entries = await loadCatalog();
    let filename;
    try {
      filename = decodeURIComponent(new URL(original).pathname.slice("/logo/".length));
    } catch {
      return remember(original, null, 5 * 6e4);
    }
    const fallback = entries?.get(filename);
    if (fallback !== void 0 && await inspect(fallback) === "image") {
      context.log.info("iptv_logo_recovered");
      return remember(original, fallback, day);
    }
    context.log.info("iptv_logo_missing");
    return remember(original, null, 5 * 6e4);
  }
  async function loadCatalog() {
    if (catalogExpires > now()) return catalog;
    if (catalogPending !== void 0) return catalogPending;
    const current = (async () => {
      try {
        const response = await context.http.fetch(catalogUrl, { headers: { Accept: "text/html" }, signal: AbortSignal.timeout(8e3) });
        if (!response.ok) {
          await response.body?.cancel();
          throw new Error("logo_catalog_http_failed");
        }
        catalog = parseLogoCatalog(await readCatalogHtml(response));
        catalogExpires = now() + day;
        context.log.info(`iptv_logo_catalog_loaded entries=${catalog.size}`);
      } catch {
        catalogExpires = now() + 5 * 6e4;
        context.log.warn("iptv_logo_catalog_unavailable");
      }
      return catalog;
    })();
    catalogPending = current;
    try {
      return await current;
    } finally {
      if (catalogPending === current) catalogPending = void 0;
    }
  }
}
async function readCatalogHtml(response) {
  if (Number(response.headers.get("content-length")) > maximumCatalogBytes || response.body === null) {
    await response.body?.cancel();
    throw new Error("logo_catalog_size_invalid");
  }
  const reader = response.body.getReader();
  const chunks = [];
  let size = 0;
  try {
    while (true) {
      const chunk = await reader.read();
      if (chunk.done) break;
      size += chunk.value.byteLength;
      if (size > maximumCatalogBytes) throw new Error("logo_catalog_too_large");
      chunks.push(chunk.value);
    }
    return Buffer.concat(chunks).toString("utf8");
  } finally {
    await reader.cancel().catch(() => {
    });
    reader.releaseLock();
  }
}

// src/index.mts
var active;
async function activate(context) {
  active = { context, store: createPlaylistStore(context), logos: createLogoResolver(context) };
  context.log.info("source_activated");
}
async function discover(request) {
  const { context, store, logos } = requireActive();
  if (request.target === null && (request.cursor !== null || request.collectionId !== null)) throw new Error("发现请求无效。");
  const playlist = await store.load();
  const categories = categoryList(playlist);
  const target = request.target ?? "all";
  const category = categories.find((entry) => entry.target === target);
  if (target !== "all" && category === void 0) throw new Error("频道分类不存在，请刷新。");
  const channels = target === "all" ? playlist.channels : playlist.channels.filter((channel) => channel.categories.includes(category.title));
  const page = paginate(channels, request.cursor, request.pageSize, target, playlist.revision);
  const collectionId = `iptv:${target}`;
  if (request.collectionId !== null && request.collectionId !== collectionId) throw new Error("频道列表标识无效。");
  const items = (await logos.prepare(page.items)).map((channel) => ({ content: summary(context, channel), rank: null, metric: null, recommendation: null }));
  const continuation = page.cursor === null ? null : { target, cursor: page.cursor };
  if (request.collectionId !== null) return { kind: "append", collectionId, items, continuation };
  const listing = {
    type: "section",
    id: `${collectionId}:section`,
    title: category?.title ?? "全部频道",
    subtitle: null,
    icon: "video",
    children: [{ type: "contentCollection", id: collectionId, layout: "list", items, continuation }]
  };
  if (request.target !== null) return { kind: "document", document: { components: [listing] } };
  return {
    kind: "document",
    document: { components: [
      { type: "section", id: "iptv:categories", title: "频道分类", subtitle: null, icon: "category", children: [
        { type: "categoryCollection", id: "iptv:category-list", layout: "chips", categories: [
          { id: "all", title: "全部频道", target: "all", count: playlist.channels.length, url: null, icon: "video" },
          ...categories
        ] }
      ] },
      listing
    ] }
  };
}
async function search(request) {
  const query = request.query.normalize("NFKC").trim().toLocaleLowerCase("zh-CN");
  if (!query) {
    if (request.cursor !== null) throw new Error("搜索游标无效。");
    return { items: [], nextCursor: null, totalCount: 0 };
  }
  if (query.length > 256) throw new Error("搜索词过长。");
  const { context, store, logos } = requireActive();
  const playlist = await store.load();
  const terms = query.split(/\s+/u);
  const channels = playlist.channels.filter((channel) => {
    const title = [channel.title, channel.name ?? "", ...channel.categories].join(" ").normalize("NFKC").toLocaleLowerCase("zh-CN");
    return terms.every((term) => title.includes(term));
  });
  const page = paginate(channels, request.cursor, request.pageSize, `search:${digest(query)}`, playlist.revision);
  return { items: (await logos.prepare(page.items)).map((channel) => summary(context, channel)), nextCursor: page.cursor, totalCount: channels.length };
}
async function searchSuggestions(_request) {
  return { items: [], nextCursor: null };
}
async function getDetail(request) {
  const { context, store, logos } = requireActive();
  const channel = (await logos.prepare([locate(await store.load(), request.id)]))[0];
  return { ...summary(context, channel), aliases: channel.name && channel.name !== channel.title ? [channel.name] : [], catalogUrl: null };
}
async function getChapters(request) {
  const { store } = requireActive();
  const channel = locate(await store.load(request.refresh === true), request.id);
  const items = channel.streams.map((stream, index) => chapter(channel, stream, index));
  return { items, groups: channel.streams.map((stream, index) => ({
    id: `group:${stream.id}`,
    title: lineTitle(stream, index),
    order: index,
    episodes: [items[index]]
  })) };
}
async function getContent(request) {
  const { context, store } = requireActive();
  const channel = locate(await store.load(true), request.id);
  const stream = channel.streams.find((entry) => chapterId(channel, entry) === request.chapterId);
  if (stream === void 0) throw new Error("直播线路不存在，请刷新频道。");
  const media = await resolveMedia(context, stream.url, channel.title);
  const headers = { Accept: "*/*" };
  return {
    chapterId: request.chapterId,
    contentKind: "video",
    title: channel.title,
    updatedAt: null,
    text: null,
    pages: [],
    media: {
      url: context.resource.proxy({ kind: media.resourceType, url: media.url, headers }),
      resourceType: media.resourceType,
      resourcePolicy: "sessionOnly",
      expiresAt: null,
      mimeType: media.mimeType,
      headers
    }
  };
}
function summary(context, channel) {
  return {
    id: channel.id,
    title: channel.title,
    contentKind: "video",
    coverOrientation: "square",
    author: null,
    url: null,
    coverUrl: channel.cover === null ? null : context.resource.proxy({ kind: "image", url: channel.cover, headers: { Accept: "image/*" } }),
    description: channel.streams.every((stream) => stream.ipv6) ? "此频道的直播线路需要 IPv6 网络。" : null,
    language: null,
    status: "ongoing",
    access: "unknown",
    wordCount: null,
    chapterCount: channel.streams.length,
    publishedAt: null,
    updatedAt: null,
    latestChapter: null,
    categories: channel.categories,
    tags: [],
    attributes: []
  };
}
function chapterId(channel, stream) {
  return `${channel.id}:${stream.id}`;
}
function lineTitle(stream, index) {
  return `线路 ${index + 1}${stream.ipv6 ? " · IPv6" : ""}`;
}
function chapter(channel, stream, index) {
  return {
    id: chapterId(channel, stream),
    title: "直播",
    order: 0,
    url: null,
    volumeTitle: lineTitle(stream, index),
    wordCount: null,
    updatedAt: null,
    isLocked: false,
    attributes: []
  };
}
function locate(playlist, id) {
  if (!/^channel:[\da-f]{24}$/u.test(id)) throw new Error("频道标识无效。");
  const channel = playlist.channels.find((entry) => entry.id === id);
  if (channel === void 0) throw new Error("上游已移除此频道，请刷新播放列表。");
  return channel;
}
function categoryList(playlist) {
  const titles = [...new Set(playlist.channels.flatMap((channel) => channel.categories))];
  if (titles.length > 32) throw new Error("频道分类超出大小限制。");
  return titles.map((title) => ({
    id: digest(title),
    title,
    target: `category:${digest(title)}`,
    count: playlist.channels.filter((channel) => channel.categories.includes(title)).length,
    url: null,
    icon: "video"
  }));
}
function paginate(items, cursor, pageSize, scope, revision) {
  if (!Number.isSafeInteger(pageSize) || pageSize < 1) throw new Error("分页大小无效。");
  const size = Math.min(50, pageSize);
  const key = digest(`${scope}:${revision}`);
  let offset = 0;
  if (cursor !== null) {
    if (cursor.length > 512 || !/^[\w-]+$/u.test(cursor)) throw new Error("列表游标无效。");
    let value;
    try {
      value = JSON.parse(Buffer.from(cursor, "base64url").toString("utf8"));
    } catch {
      throw new Error("列表游标无效。");
    }
    if (!Array.isArray(value) || value.length !== 3 || value[0] !== key || value[1] !== size || !Number.isSafeInteger(value[2]) || value[2] < 1 || value[2] >= items.length || value[2] % size !== 0) {
      throw new Error("列表已更新或游标无效，请刷新。");
    }
    offset = value[2];
  }
  const page = items.slice(offset, offset + size);
  const next = offset + page.length;
  return { items: page, cursor: next < items.length ? Buffer.from(JSON.stringify([key, size, next])).toString("base64url") : null };
}
function requireActive() {
  if (active === void 0) throw new Error("数据源尚未激活。");
  return active;
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
