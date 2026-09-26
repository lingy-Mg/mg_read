import { createRequire as __mgreadCreateRequire } from 'node:module'; const require = __mgreadCreateRequire(import.meta.url);

// src/catalog.mts
import { createHash } from "node:crypto";
var cache = /* @__PURE__ */ new Map();
var pending = /* @__PURE__ */ new Map();
var generation = 0;
function clearCatalogCache() {
  generation++;
  cache.clear();
  pending.clear();
}
async function catalogData(id, fetch, refresh = false) {
  if (refresh) clearCatalogCache();
  const hit = cache.get(id);
  if (hit && hit.expires > Date.now()) {
    cache.delete(id);
    cache.set(id, hit);
    return hit.value;
  }
  cache.delete(id);
  const running = pending.get(id);
  if (running) return running;
  const epoch = generation;
  const task = fetch().then((value) => {
    const bytes = Buffer.byteLength(JSON.stringify(value));
    if (generation === epoch && bytes <= 32 * 1024 * 1024) {
      cache.set(id, { value, bytes, expires: Date.now() + 5 * 6e4 });
      while (cache.size > 2 || [...cache.values()].reduce((sum, entry) => sum + entry.bytes, 0) > 32 * 1024 * 1024) {
        cache.delete(cache.keys().next().value);
      }
    }
    return value;
  }).finally(() => {
    if (pending.get(id) === task) pending.delete(id);
  });
  pending.set(id, task);
  return task;
}
var records = (value) => Array.isArray(value) ? value.filter((v) => !!v && typeof v === "object") : [];
function chapterCatalog(id, data, request) {
  const players = records(data.playerList).filter((player) => records(player.epList).length > 0);
  const total = players.reduce((sum, player) => sum + records(player.epList).length, 0);
  const large = total > 1e3 && players.length > 1;
  const lazy = large && request.supportsDeferredGroups === true;
  const groups = players.map((player, order) => {
    const title = String(player.playerName || `线路 ${order + 1}`);
    const identity = String(player.playerId ?? player.id ?? title);
    const groupId = large ? `group:${id}:${createHash("sha256").update(identity).digest("hex").slice(0, 24)}` : `group:${id}:${order}`;
    const deferred = lazy && (request.groupId ? groupId !== request.groupId : order !== 0);
    const episodes2 = deferred ? [] : records(player.epList).filter((episode) => /^\d+$/u.test(String(episode.epId))).map((episode, index) => ({
      id: `vod:${id}:${episode.epId}`,
      title: String(episode.epName || `第 ${index + 1} 集`),
      order: index,
      url: null,
      volumeTitle: title,
      wordCount: null,
      updatedAt: null,
      isLocked: false,
      attributes: []
    }));
    return { id: groupId, title, order, episodes: episodes2, ...deferred ? { deferred: true } : {} };
  });
  if (request.groupId && !groups.some((group) => group.id === request.groupId)) throw new Error("Requested line is unavailable.");
  return { groups, items: groups.flatMap((group) => group.episodes) };
}

// src/index.mts
import { createHash as createHash2, randomUUID } from "node:crypto";
var deferredGroups = true;
var hosts = ["https://yz1018.ln2tn3kf2.com", "https://yz260605.z5fl9630.com", "https://yz260324.z2g1uoqy.com", "https://yz260324.c628uthq.com", "https://yz260324.nv153kfl.com", "https://cfvip.eiq9rzoe.com", "https://yz260605.jpknq5ju.com"];
var appKey = "f384b87cc9ef41e4842dda977bae2c7f";
var common = { appId: "fea23e11fc1241409682880e15fb2851", bundlerId: "com.murqanzze.ts", cus1tom: "cus3tom", deviceInfo: "NX809J", osInfo: "14", otherParam: "1", patchNumber: 0, source: "wap_jztv3", version: "1.0.43", versionCode: 1003 };
var headers = { "Content-Type": "application/json", "User-Agent": "okhttp/4.12.0" };
var channels = Object.freeze([{ id: "short", title: "短剧", topicId: 47 }, { id: "netflix", title: "奈飞 Netflix", topicId: 5 }, { id: "movie", title: "电影", topicId: 67 }, { id: "series", title: "电视剧", topicId: 68 }, { id: "anime", title: "动漫", topicId: 14 }, { id: "variety", title: "综艺", topicId: 16 }, { id: "korea", title: "高清韩剧", topicId: 63 }, { id: "sports", title: "体育", topicId: 55 }]);
var homeSections = Object.freeze([{ channelId: "short", sectionId: "juzi-home-short-section", collectionId: "juzi-home-short-items", title: "短剧速看", subtitle: "橘子 TV 短剧专题", icon: "video", layout: "carousel" }, { channelId: "movie", sectionId: "juzi-home-movie-section", collectionId: "juzi-home-movie-items", title: "电影剧场", subtitle: "发现电影专题内容", icon: "video", layout: "coverGrid" }, { channelId: "series", sectionId: "juzi-home-series-section", collectionId: "juzi-home-series-items", title: "连续剧场", subtitle: "根据来源进度继续追剧", icon: "ongoing", layout: "shelf" }]);
var context;
var udid = randomUUID();
var activeHost = hosts[0] ?? "";
async function activate(next) {
  clearCatalogCache();
  context = next;
  udid = randomUUID();
  activeHost = hosts[0] ?? "";
  next.log.info("source_activated");
}
async function search(request) {
  const query = request.query.trim();
  if (query === "") return frozen({ items: [], nextCursor: null, totalCount: 0 });
  if (request.cursor !== null) throw new Error("Cursor is invalid.");
  const response = await post("/v1/api/search/search", { keyword: query, nextVal: "" }), items = summaries(records2(object(response.data).items)).slice(0, clamp(request.pageSize));
  return frozen({ items, nextCursor: null, totalCount: items.length });
}
async function searchSuggestions(_request) {
  return frozen({ items: [], nextCursor: null });
}
async function discover(request) {
  if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null) throw new Error("Home discovery continuation is invalid.");
    const size2 = Math.min(clamp(request.pageSize), 8), collections = [];
    for (const spec of homeSections) {
      const channel2 = channels.find((value) => value.id === spec.channelId);
      if (!channel2) continue;
      try {
        const response2 = await post("/v1/api/vodTopic/getVodList", { vodTopicId: channel2.topicId, pageIndex: 1, pageSize: size2 }), data2 = object(response2.data), contents2 = summaries(records2(first(data2.items, data2.vodList, data2.list))).slice(0, size2);
        if (contents2.length !== 0) collections.push({ spec, contents: contents2 });
      } catch {
        requireContext().log.warn(`source_discovery_home_${spec.channelId}_unavailable`);
      }
    }
    return frozen({ kind: "document", document: { components: homeComponents(collections) } });
  }
  const channel = channels.find((value) => request.target === `channel:${value.id}`);
  if (!channel) throw new Error("Discovery target is invalid.");
  const page = cursorPage(request.cursor, request.target), size = clamp(request.pageSize), response = await post("/v1/api/vodTopic/getVodList", { vodTopicId: channel.topicId, pageIndex: page, pageSize: size }), data = object(response.data), values = records2(first(data.items, data.vodList, data.list)), contents = summaries(values).slice(0, size), collectionId = `juzi:${channel.id}`, items = contents.map((content) => frozen({ content, rank: null, metric: null, recommendation: null })), totalPages = Number(data.totalPages), continuation = (Number.isSafeInteger(totalPages) ? page < totalPages : values.length >= size) ? frozen({ target: request.target, cursor: `channel:${channel.id}:${page + 1}` }) : null;
  if (request.collectionId !== null) {
    if (request.collectionId !== collectionId) throw new Error("Discovery collection is invalid.");
    return frozen({ kind: "append", collectionId, items, continuation });
  }
  return frozen({ kind: "document", document: { components: [{ type: "section", id: `${collectionId}:section`, title: channel.title, subtitle: null, icon: channelIcon(channel.id), children: [{ type: "contentCollection", id: collectionId, layout: "coverGrid", items, continuation }] }] } });
}
async function getDetail(request) {
  const id = contentId(request.id), data = await catalogData(id, async () => object((await post("/v2/api/vodInfo/index", { vodId: Number(id) })).data)), item = summary(data, id);
  return frozen({ ...item, aliases: [], catalogUrl: null, chapterCount: episodes(data).length });
}
async function getChapters(request) {
  const id = contentId(request.id), data = await catalogData(id, async () => object((await post("/v2/api/vodInfo/index", { vodId: Number(id) })).data), request.refresh === true);
  return frozen(chapterCatalog(id, data, request));
}
async function getContent(request) {
  const id = contentId(request.id), epId = chapterNative(request.chapterId, id), options = records2((await post("/v2/api/vodInfo/epDetail", { vodEpId: Number(epId) })).data), resolutions = [...new Set([...options.filter((value) => value.canPlay !== false).map((value) => Number(value.vodResolution)), 3, 2, 1].filter((value) => Number.isSafeInteger(value) && value > 0))];
  let upstream = "";
  for (const resolution of resolutions) {
    try {
      const data = object((await post("/v2/api/vodInfo/playUrl", { epId: Number(epId), vodResolution: resolution })).data);
      upstream = text(data.playUrl);
      if (safeUrl(upstream)) break;
    } catch {
      continue;
    }
  }
  if (!safeUrl(upstream)) throw new Error("Video address is unavailable.");
  const resourceType = /\.m3u8(?:$|[?#])/iu.test(upstream) ? "hls" : "video", mediaHeaders = { "User-Agent": "Mozilla/5.0", Referer: "https://55.app/" };
  return frozen({ chapterId: request.chapterId, contentKind: "video", title: null, updatedAt: null, text: null, pages: [], media: { url: requireContext().resource.proxy({ kind: resourceType, url: upstream, headers: mediaHeaders }), resourceType, resourcePolicy: "sessionOnly", expiresAt: null, mimeType: resourceType === "hls" ? "application/vnd.apple.mpegurl" : "video/mp4", headers: mediaHeaders } });
}
async function post(path, extra) {
  const body = sign({ ...common, ...extra, udid, requestId: randomUUID() }), payload = JSON.stringify(body), ordered = [activeHost, ...hosts.filter((host) => host !== activeHost)];
  let last = "";
  for (const host of ordered) {
    try {
      const response = await requireContext().http.fetch(`${host}${path}`, { method: "POST", headers, body: payload });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const value = object(JSON.parse(await response.text()));
      if (value.result) {
        activeHost = host;
        return value;
      }
      throw new Error(text(value.msg) || "Upstream rejected request.");
    } catch (error) {
      last = error instanceof Error ? error.message : String(error);
    }
  }
  throw new Error(`Juzi request failed: ${last}`);
}
function sign(value) {
  const canonical = Object.keys(value).filter((key) => key !== "sign" && value[key] !== void 0 && value[key] !== null && value[key] !== "").sort().map((key) => `${key}=${String(value[key])}`).concat(`appKey=${appKey}`).join("&");
  return { ...value, sign: createHash2("md5").update(canonical).digest("hex") };
}
function homeComponents(collections) {
  const components = [];
  const first2 = collections.find((value) => value.spec.channelId === "short");
  if (first2) components.push(homeSection(first2.spec, first2.contents));
  components.push(frozen({ type: "group", id: "juzi-home-navigation", layout: "vertical", children: [frozen({ type: "section", id: "juzi-home-channels-section", title: "频道漫游", subtitle: "短剧、电影、动漫与综艺，一键直达", icon: "category", children: [frozen({ type: "categoryCollection", id: "juzi-channel-list", layout: "grid", categories: channels.map((channel) => frozen({ id: `channel:${channel.id}`, title: channel.title, target: `channel:${channel.id}`, count: null, url: null, icon: channelIcon(channel.id) })) })] })] }));
  for (const collection of collections) {
    if (collection !== first2) components.push(homeSection(collection.spec, collection.contents));
  }
  return components;
}
function homeSection(spec, contents) {
  return frozen({ type: "section", id: spec.sectionId, title: spec.title, subtitle: spec.subtitle, icon: spec.icon, children: [frozen({ type: "contentCollection", id: spec.collectionId, layout: spec.layout, items: contents.map(homeItem), continuation: null })] });
}
function homeItem(content) {
  const update = content.latestChapter?.title ?? null;
  return frozen({ content, rank: null, metric: update === null ? null : frozen({ label: "更新", value: update }), recommendation: null });
}
function channelIcon(id) {
  if (id === "netflix" || id === "korea") return "globe";
  if (id === "series") return "ongoing";
  if (id === "anime") return "manga";
  if (id === "variety") return "star";
  if (id === "sports") return "sports";
  return "video";
}
function summaries(values) {
  const result = /* @__PURE__ */ new Map();
  for (const value of values) {
    const id = sourceId(first(value.vodId, value.id));
    if (id && text(first(value.vodName, value.name))) result.set(id, summary(value, id));
  }
  return [...result.values()];
}
function summary(value, id) {
  const latest = nullable(first(value.remark, value.updateRemark));
  return frozen({ id: `vod:${id}`, title: text(first(value.vodName, value.name)) || id, contentKind: "video", coverOrientation: "portrait", author: nullable(value.flags), url: null, coverUrl: proxyImage(text(first(value.coverImg, value.coverUrl))), description: nullable(first(value.intro, value.watchingCountDesc)), language: "zh-CN", status: "unknown", access: "unknown", wordCount: null, chapterCount: null, publishedAt: null, updatedAt: null, latestChapter: latest ? { id: `vod:${id}:latest`, title: latest, url: null, updatedAt: null } : null, categories: stringList([value.flags, value.areaName, value.year]), tags: [], attributes: [] });
}
function episodes(data) {
  const result = [];
  for (const [playerIndex, player] of records2(data.playerList).entries()) {
    const group = text(player.playerName) || `线路 ${playerIndex + 1}`;
    for (const [episodeIndex, episode] of records2(player.epList).entries()) {
      const id = sourceId(episode.epId);
      if (id) result.push({ id, title: text(episode.epName) || `第 ${episodeIndex + 1} 集`, group });
    }
  }
  return result;
}
function sourceId(value) {
  const id = text(value);
  return /^\d+$/u.test(id) ? id : null;
}
function contentId(id) {
  const value = /^vod:(\d+)$/u.exec(id)?.[1];
  if (!value) throw new Error("Content ID is invalid.");
  return value;
}
function chapterNative(id, content) {
  const value = new RegExp(`^vod:${content}:(\\d+)$`, "u").exec(id)?.[1];
  if (!value) throw new Error("Chapter ID is invalid.");
  return value;
}
function proxyImage(url) {
  return safeUrl(url) ? requireContext().resource.proxy({ kind: "image", url, headers: { Referer: "https://55.app/" } }) : null;
}
function safeUrl(value) {
  try {
    return ["http:", "https:"].includes(new URL(value).protocol);
  } catch {
    return false;
  }
}
function cursorPage(cursor, target) {
  if (cursor === null) return 1;
  const page = Number(cursor.startsWith(`${target}:`) ? cursor.slice(target.length + 1) : "");
  if (!Number.isSafeInteger(page) || page < 2) throw new Error("Cursor is invalid.");
  return page;
}
function stringList(values) {
  return [...new Set(values.map(text).filter(Boolean))];
}
function records2(value) {
  return Array.isArray(value) ? value.filter(isObject) : [];
}
function object(value) {
  return isObject(value) ? value : {};
}
function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
function first(...values) {
  return values.find((value) => value !== null && value !== void 0 && value !== "") ?? "";
}
function text(value) {
  return typeof value === "string" ? value.trim() : typeof value === "number" ? String(value) : "";
}
function nullable(value) {
  return text(value) || null;
}
function clamp(value) {
  return Math.max(1, Math.min(50, Math.floor(value)));
}
function frozen(value) {
  return Object.freeze(value);
}
function requireContext() {
  if (!context) throw new Error("Source is not activated.");
  return context;
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
