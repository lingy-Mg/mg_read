import { createRequire as __mgreadCreateRequire } from 'node:module'; const require = __mgreadCreateRequire(import.meta.url);

// src/index.mts
import { createDecipheriv, createHash } from "node:crypto";
import { setTimeout as delay } from "node:timers/promises";

// src/library.mts
var fields = ["area", "by", "class", "letter", "year"];
var labels = /* @__PURE__ */ new Map([["类型", "type"], ["剧情", "class"], ["地区", "area"], ["年份", "year"], ["字母", "letter"], ["排序", "by"]]);
function libraryState(target) {
  if (target === "category:library") return { type: "1" };
  if (!/^library:[A-Za-z0-9_-]{1,1500}$/u.test(target)) throw new Error("Library target is invalid.");
  let value;
  try {
    value = JSON.parse(Buffer.from(target.slice(8), "base64url").toString("utf8"));
  } catch {
    throw new Error("Library target is invalid.");
  }
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw new Error("Library target is invalid.");
  const state = value;
  if (typeof state.type !== "string" || !/^\d{1,3}$/u.test(state.type) || Object.keys(state).some((key) => key !== "type" && !fields.includes(key))) {
    throw new Error("Library target is invalid.");
  }
  for (const field of fields) {
    const entry = state[field];
    if (entry !== void 0 && (typeof entry !== "string" || !/^[A-Za-z0-9\u3400-\u4dbf\u4e00-\u9fff -]{1,40}$/u.test(entry))) throw new Error("Library filter is invalid.");
  }
  return state;
}
function libraryRoute(state, page = 1) {
  const suffix = fields.filter((field) => state[field] !== void 0).map((field) => `/${field}/${encodeURIComponent(state[field])}`).join("");
  return `/w/${state.type}${suffix}${page > 1 ? `/page/${page}` : ""}.html`;
}
function libraryHasNext(html, state, page) {
  for (const anchor of html.matchAll(/<a\b([^>]*)>/giu)) {
    const href = attribute(anchor[1], "href");
    if (href === null) continue;
    const match = /\/page\/(\d+)\.html$/u.exec(href);
    if (Number(match?.[1]) !== page + 1) continue;
    const next = targetFromRoute(href.replace(/\/page\/\d+\.html$/u, ".html"));
    if (next !== null && libraryRoute(next.state) === libraryRoute(state)) return true;
  }
  return false;
}
function targetFromRoute(href) {
  const match = /^\/w\/(\d{1,3})((?:\/(?:area|by|class|letter|year)\/[^/]+)*)\.html$/u.exec(href);
  if (match === null) return null;
  const state = { type: match[1] };
  const parts = match[2].split("/").slice(1);
  for (let i = 0; i < parts.length; i += 2) {
    try {
      state[parts[i]] = decodeURIComponent(parts[i + 1]);
    } catch {
      return null;
    }
  }
  const ordered = { type: state.type };
  for (const field of fields) if (state[field] !== void 0) ordered[field] = state[field];
  const target = `library:${Buffer.from(JSON.stringify(ordered)).toString("base64url")}`;
  libraryState(target);
  return { target, state: ordered };
}
function libraryFilters(html) {
  const groups = [];
  const rows = /<div\b[^>]*class=["'][^"']*\bmodule-item-title\b[^"']*["'][^>]*>([\s\S]*?)<\/div>\s*<div\b[^>]*class=["'][^"']*\bmodule-item-box\b[^"']*["'][^>]*>([\s\S]*?)<\/div>/giu;
  for (const row of html.matchAll(rows)) {
    const label = plain(row[1]);
    const field = labels.get(label);
    if (field === void 0) continue;
    const tabs = [];
    let selectedTabId = null;
    const seen = /* @__PURE__ */ new Set();
    for (const anchor of row[2].matchAll(/<a\b([^>]*)>([\s\S]*?)<\/a>/giu)) {
      const href = attribute(anchor[1], "href");
      const title = plain(anchor[2]);
      const option = href === null ? null : targetFromRoute(href);
      if (option === null || title === "") continue;
      const id = `${field}:${Buffer.from(option.state[field] ?? "all").toString("base64url")}`;
      if (seen.has(id)) continue;
      seen.add(id);
      tabs.push({ id, label: title, target: option.target });
      if ((attribute(anchor[1], "class") ?? "").split(/\s+/u).includes("active")) selectedTabId = id;
    }
    if (tabs.length > 0) groups.push({
      id: field,
      label,
      selectedOptionId: selectedTabId,
      options: tabs
    });
  }
  return groups.length === 0 ? [] : [{ type: "filters", id: "library-filters", resetTarget: "category:library", groups }];
}
function attribute(html, name) {
  return new RegExp(`\\b${name}\\s*=\\s*["']([^"']*)["']`, "iu").exec(html)?.[1]?.replaceAll("&amp;", "&") ?? null;
}
function plain(html) {
  return html.replace(/<[^>]*>/gu, "").replaceAll("&nbsp;", " ").replaceAll("&amp;", "&").trim();
}

// src/discovery.mts
function categoryPanels(html, id, title) {
  const panels = modulePanels(html);
  if (id !== "week") {
    if (panels[0] === void 0) throw new Error("Category listing is unavailable.");
    return [{ id, title, html: panels[0] }];
  }
  const days = [...html.matchAll(/<span\b[^>]*\bdata-dropdown-value=["'](周[一二三四五六日])["'][^>]*>/gu)].map((match) => match[1]);
  if (days.length !== 7 || new Set(days).size !== 7 || panels.length !== 7) {
    throw new Error("Weekly schedule is unavailable.");
  }
  return panels.map((body, index) => ({ id: `week:${index + 1}`, title: days[index], html: body }));
}
function modulePanels(html) {
  const panels = [];
  let start = -1;
  let depth = 0;
  for (const match of html.matchAll(/<\/?div\b[^>]*>/giu)) {
    if (/^<\//u.test(match[0])) {
      if (start >= 0 && --depth === 0) {
        panels.push(html.slice(start, match.index));
        start = -1;
      }
    } else if (start >= 0) {
      depth += 1;
    } else {
      const classes = /\bclass=["']([^"']*)["']/iu.exec(match[0])?.[1]?.split(/\s+/u) ?? [];
      if (classes.includes("module-main") && classes.includes("tab-list")) {
        start = match.index + match[0].length;
        depth = 1;
      }
    }
  }
  return panels;
}

// src/hls-policy.mts
var hlsAdFilter = Object.freeze({
  algorithm: "sequence-islands-v1",
  maximumInterstitialSeconds: 90,
  maximumInterstitialSegments: 32,
  minimumContentSegments: 30,
  minimumContentDurationRatio: 0.85,
  minimumFeatureContrast: 0.2
});

// src/index.mts
var base = "https://www.yinhuadm.xyz";
var playerBase = "https://player.mcue.cc";
var playerSalt = "lemon";
var defaultRequestAttempts = 3;
var mcueRequestAttempts = 2;
var mcueRequestTimeoutMs = 6e3;
var retryDelayMs = 150;
var directProxyMode = "direct";
var pageHeaders = Object.freeze({
  Accept: "text/html,application/xhtml+xml,application/xml;q=0.9,application/json,text/plain,*/*;q=0.8",
  "Accept-Language": "zh-CN,zh;q=0.9",
  Referer: `${base}/`,
  "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36"
});
var categories = Object.freeze([
  ["library", "动漫库", "/w/1.html"],
  ["today", "今日更新", "/label/new.html"],
  ["hot", "热榜", "/label/hot.html"],
  ["week", "本周追番", "/label/week.html"],
  ["new", "新片上线", "/s/1.html"]
]);
var context;
async function activate(next) {
  context = next;
  next.log.info("source_activated");
}
async function search(request) {
  const query = request.query.trim();
  if (query === "") return frozen({ items: [], nextCursor: null, totalCount: 0 });
  const page = searchPage(request.cursor);
  const pageSize = clamp(request.pageSize);
  const path = page === 1 ? `/vch/${encodeURIComponent(query)}.html` : `/vch/${encodeURIComponent(query)}/page/${page}.html`;
  const primary = parseListing(await fetchText(`${base}${path}`));
  let values = primary;
  if (page === 1 && !primary.some((item) => sameSearchTitle(item.title, query))) {
    const currentMatches = parseCategory(await fetchText(`${base}/label/new.html`), "today", "今日更新")[0].items.filter((item) => sameSearchTitle(item.title, query));
    values = uniqueById([...currentMatches, ...primary]);
  }
  const items = values.slice(0, pageSize);
  return frozen({
    items,
    nextCursor: primary.length >= pageSize && page < 50 ? `search:${page + 1}` : null,
    totalCount: null
  });
}
async function searchSuggestions(_request) {
  return frozen({ items: [], nextCursor: null });
}
async function discover(request) {
  if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null) throw new Error("Initial discovery request is invalid.");
    return rootDocument(request.pageSize);
  }
  if (request.target === "category:library" || request.target.startsWith("library:")) {
    const state = libraryState(request.target);
    const page = request.cursor === null ? 1 : Number(new RegExp(`^${escape(request.target)}:(\\d+)$`, "u").exec(request.cursor)?.[1]);
    if (!Number.isSafeInteger(page) || page < 1 || page > 1e4 || request.cursor !== null && page < 2) throw new Error("Library cursor is invalid.");
    const collectionId = "video:library";
    if (request.collectionId !== null && request.collectionId !== collectionId) throw new Error("Discovery collection is invalid.");
    const html = await fetchText(`${base}${libraryRoute(state, page)}`);
    const values = parseListing(html).slice(0, 50);
    const items = values.map((content) => frozen({ content, rank: null, metric: null, recommendation: null }));
    const continuation = page < 1e4 && libraryHasNext(html, state, page) ? { target: request.target, cursor: `${request.target}:${page + 1}` } : null;
    if (request.collectionId !== null) return frozen({ kind: "append", collectionId, items, continuation });
    return frozen({ kind: "document", document: { components: [
      ...libraryFilters(html),
      {
        type: "section",
        id: "library-results",
        title: "动漫库",
        subtitle: null,
        children: [{ type: "contentCollection", id: collectionId, layout: "coverGrid", items, continuation }]
      }
    ] } });
  }
  const category = categories.find(([id]) => request.target === `category:${id}`);
  if (category === void 0) throw new Error("Discovery target is invalid.");
  if (request.cursor !== null) throw new Error("Discovery cursor is invalid.");
  const [, title, route] = category;
  const panels = parseCategory(await fetchText(`${base}${route}`), category[0], title);
  const components = panels.map((panel) => {
    const children = [];
    for (let start = 0; start < Math.max(1, panel.items.length); start += 50) {
      children.push({
        type: "contentCollection",
        id: `video:${panel.id}${start === 0 ? "" : `:part:${start / 50 + 1}`}`,
        layout: "coverGrid",
        continuation: null,
        items: panel.items.slice(start, start + 50).map((content) => frozen({ content, rank: null, metric: null, recommendation: null }))
      });
    }
    return { type: "section", id: `video:${panel.id}:section`, title: panel.title, subtitle: null, icon: "video", children };
  });
  if (request.collectionId !== null) {
    const collection = components.flatMap((component) => component.children).find((value) => value.id === request.collectionId);
    if (collection === void 0) throw new Error("Discovery collection is invalid.");
    return frozen({ kind: "append", collectionId: collection.id, items: collection.items, continuation: null });
  }
  return frozen({ kind: "document", document: { components } });
}
async function getDetail(request) {
  const id = contentId(request.id);
  return parseDetail(await fetchText(detailUrl(id)), id);
}
async function getChapters(request) {
  const id = contentId(request.id);
  const groups = parseGroups(await fetchText(detailUrl(id)), id);
  const items = groups.flatMap((group) => group.episodes).map((episode, order) => frozen({ ...episode, order }));
  return frozen({ items, groups });
}
async function getContent(request) {
  const id = contentId(request.id);
  const chapter = parseChapterId(request.chapterId, id);
  const page = playUrl(id, chapter.line, chapter.episode);
  const player = parsePlayerData(await fetchText(page));
  const resolved = await resolvePlayerUrl(player, page);
  if (!safeMediaUrl(resolved.url)) throw new Error("Playback address is unavailable.");
  const resourceType = /\.m3u8(?:$|[?#])/iu.test(resolved.url) ? "hls" : "video";
  const mediaHeaders = { Referer: resolved.referer, "User-Agent": pageHeaders["User-Agent"] };
  return frozen({
    chapterId: request.chapterId,
    contentKind: "video",
    title: null,
    updatedAt: null,
    text: null,
    pages: [],
    media: {
      url: requireContext().resource.proxy({
        kind: resourceType,
        url: resolved.url,
        headers: mediaHeaders,
        proxyMode: directProxyMode,
        ...resourceType === "hls" ? { hlsAdFilter } : {}
      }),
      resourceType,
      resourcePolicy: "sessionOnly",
      expiresAt: null,
      mimeType: resourceType === "hls" ? "application/vnd.apple.mpegurl" : "video/mp4",
      headers: mediaHeaders
    }
  });
}
async function rootDocument(pageSize) {
  const limit = Math.min(clamp(pageSize), 12);
  const values = parseCategory(await fetchText(`${base}/label/new.html`), "today", "今日更新")[0].items.slice(0, limit);
  const items = values.map((content) => frozen({ content, rank: null, metric: null, recommendation: null }));
  const components = [];
  if (items.length > 0) {
    components.push({
      type: "section",
      id: "video-featured",
      title: "今日更新",
      subtitle: "近期更新的动漫",
      icon: "hot",
      children: [{ type: "contentCollection", id: "video-featured-list", layout: "coverGrid", items, continuation: null }]
    });
  }
  components.push({
    type: "section",
    id: "video-categories",
    title: "动漫分类",
    subtitle: "按栏目继续发现",
    icon: "video",
    children: [{
      type: "categoryCollection",
      id: "video-categories-list",
      layout: "chips",
      categories: categories.map(([id, title]) => ({ id, title, target: `category:${id}`, count: null, url: null, icon: "video" }))
    }]
  });
  return frozen({ kind: "document", document: { components } });
}
async function fetchText(url, options = {}) {
  const attempts = options.attempts ?? defaultRequestAttempts;
  const timeoutSignal = options.timeoutMs === void 0 ? void 0 : AbortSignal.timeout(options.timeoutMs);
  let lastStatus = 0;
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    if (timeoutSignal?.aborted === true) break;
    let retry = false;
    try {
      const response = await requireContext().http.fetch(url, {
        headers: pageHeaders,
        proxyMode: directProxyMode,
        ...timeoutSignal === void 0 ? {} : { signal: timeoutSignal }
      });
      if (response.ok) {
        lastStatus = 0;
        return await response.text();
      }
      lastStatus = response.status;
      await response.body?.cancel().catch(() => void 0);
      retry = retryableStatus(response.status);
    } catch {
      retry = timeoutSignal === void 0 || !timeoutSignal.aborted;
    }
    if (!retry || attempt + 1 >= attempts) break;
    requireContext().log.warn("source_request_retry");
    await delay(retryDelayMs * (attempt + 1));
  }
  if (timeoutSignal?.aborted === true) throw new Error("Source request timed out.");
  if (lastStatus > 0) throw new Error(`Source request failed with status ${lastStatus}.`);
  throw new Error("Source request failed.");
}
function retryableStatus(status) {
  return status === 408 || status === 425 || status === 429 || status >= 500;
}
function parseListing(html) {
  const unique = /* @__PURE__ */ new Map();
  for (const match of html.matchAll(/<a\b([^>]*)>([\s\S]*?)<\/a>/giu)) {
    const attributes = match[1] ?? "";
    const body = match[2] ?? "";
    const href = attribute2(attributes, "href");
    const id = /\/v\/(\d+)\.html(?:[?#]|$)/iu.exec(href)?.[1];
    if (id === void 0 || unique.has(id)) continue;
    const image = /<img\b[^>]*>/iu.exec(body)?.[0] ?? "";
    const title = cleanTitle(
      attribute2(attributes, "title") || attribute2(image, "alt") || firstText(body, /<[^>]*class=["'][^"']*module-poster-item-title[^"']*["'][^>]*>([\s\S]*?)<\/[^>]+>/iu) || strip(body)
    );
    if (title === "") continue;
    const cover = attribute2(image, "data-original") || attribute2(image, "data-src") || attribute2(image, "src");
    const latest = firstText(body, /<[^>]*class=["'][^"']*module-item-note[^"']*["'][^>]*>([\s\S]*?)<\/[^>]+>/iu);
    unique.set(id, summary(id, title, cover, latest || null));
  }
  return [...unique.values()];
}
function sameSearchTitle(title, query) {
  return normalizeSearchTitle(title) === normalizeSearchTitle(query);
}
function normalizeSearchTitle(value) {
  return decode(value).normalize("NFKC").replace(/[\s《》「」『』【】（）()]/gu, "").toLocaleLowerCase("zh-CN");
}
function uniqueById(items) {
  return [...new Map(items.map((item) => [item.id, item])).values()];
}
function parseDetail(html, id) {
  const title = cleanTitle(firstText(html, /<h1\b[^>]*>([\s\S]*?)<\/h1>/iu)) || `视频 ${id}`;
  const coverContainer = /<[^>]*class=["'][^"']*(?:module-item-cover|module-item-pic)[^"']*["'][^>]*>([\s\S]*?)<\/[^>]+>/iu.exec(html)?.[1] ?? "";
  const coverImage = /<img\b[^>]*>/iu.exec(coverContainer)?.[0] ?? "";
  const cover = firstAttribute(html, /<meta\b[^>]*property=["']og:image["'][^>]*>/iu, "content") || attribute2(coverImage, "data-original") || attribute2(coverImage, "data-src") || attribute2(coverImage, "src");
  const description = firstText(html, /<[^>]*class=["'][^"']*(?:module-info-introduction|vod_content)[^"']*["'][^>]*>([\s\S]*?)<\/[^>]+>/iu);
  const latest = firstText(html, /<[^>]*class=["'][^"']*module-item-note[^"']*["'][^>]*>([\s\S]*?)<\/[^>]+>/iu);
  const tags = uniqueText([...html.matchAll(/<a\b([^>]*)>([\s\S]*?)<\/a>/giu)].filter((match) => /\/w\//iu.test(attribute2(match[1] ?? "", "href"))).map((match) => strip(match[2] ?? "")));
  const item = summary(id, title, cover, latest || null, description || null, tags);
  return frozen({ ...item, aliases: [], catalogUrl: item.url });
}
function summary(id, title, cover, latestChapterTitle, description = null, tags = []) {
  if (!/^\d+$/u.test(id)) throw new Error("Source item has no ID.");
  return frozen({
    id: `video:${id}`,
    title: decode(title) || `视频 ${id}`,
    contentKind: "video",
    coverOrientation: "portrait",
    author: null,
    url: detailUrl(id),
    coverUrl: proxyCover(cover),
    description,
    language: "zh-CN",
    status: "unknown",
    access: "unknown",
    wordCount: null,
    chapterCount: null,
    publishedAt: null,
    updatedAt: null,
    latestChapter: projectLatestChapter(latestChapterTitle),
    categories: tags,
    tags,
    attributes: []
  });
}
function parseGroups(html, id) {
  const groupTitles = groupTitlesByLine(html, id, parseGroupTitles(html));
  const byLine = /* @__PURE__ */ new Map();
  const seen = /* @__PURE__ */ new Set();
  for (const match of html.matchAll(/<a\b([^>]*)>([\s\S]*?)<\/a>/giu)) {
    const href = attribute2(match[1] ?? "", "href");
    const parsed = new RegExp(`/p/${id}-(\\d+)-(\\d+)\\.html`, "iu").exec(href);
    if (parsed?.[1] === void 0 || parsed[2] === void 0) continue;
    const line = Number(parsed[1]);
    const episode = Number(parsed[2]);
    const key = `${line}:${episode}`;
    if (!Number.isSafeInteger(line) || !Number.isSafeInteger(episode) || seen.has(key)) continue;
    seen.add(key);
    const title = cleanEpisodeTitle(attribute2(match[1] ?? "", "title") || strip(match[2] ?? ""), episode);
    const entries = byLine.get(line) ?? [];
    entries.push({ episode, title });
    byLine.set(line, entries);
  }
  const groups = [...byLine.entries()].map(([line, entries], groupOrder) => {
    entries.sort((left, right) => left.episode - right.episode);
    const groupTitle = groupTitles.get(line) ?? `线路 ${line}`;
    const episodes = entries.map((entry, order) => frozen({
      id: `video:${id}:${line}:${entry.episode}`,
      title: entry.title,
      order,
      url: playUrl(id, String(line), String(entry.episode)),
      volumeTitle: groupTitle,
      wordCount: null,
      updatedAt: null,
      isLocked: null,
      attributes: []
    }));
    return frozen({ id: `group:${id}:${line}`, title: groupTitle, order: groupOrder, episodes });
  });
  if (groups.length === 0) throw new Error("No playable episodes found.");
  return groups;
}
function parseGroupTitles(html) {
  const titles = [];
  for (const match of html.matchAll(/<div\b([^>]*)>/giu)) {
    const attributes = match[1] ?? "";
    if (!attribute2(attributes, "class").split(/\s+/u).includes("module-tab-item")) continue;
    const bodyStart = (match.index ?? 0) + match[0].length;
    const bodyEnd = html.indexOf("</div>", bodyStart);
    const body = bodyEnd < 0 ? "" : html.slice(bodyStart, bodyEnd);
    const value = attribute2(attributes, "data-dropdown-value") || firstText(body, /<span\b[^>]*>([\s\S]*?)<\/span>/iu) || strip(body).replace(/\d+$/u, "").trim();
    if (value !== "" && value.length <= 80) titles.push(value);
  }
  return titles;
}
function groupTitlesByLine(html, id, titles) {
  const starts = [...html.matchAll(/<div\b([^>]*)>/giu)].filter((match) => attribute2(match[1] ?? "", "class").split(/\s+/u).includes("module-play-list")).map((match) => match.index);
  const byLine = /* @__PURE__ */ new Map();
  for (let index = 0; index < starts.length; index += 1) {
    const title = titles[index];
    if (title === void 0) continue;
    const start = starts[index] ?? 0;
    const end = starts[index + 1] ?? html.length;
    const line = Number(new RegExp(`/p/${id}-(\\d+)-\\d+\\.html`, "iu").exec(html.slice(start, end))?.[1]);
    if (Number.isSafeInteger(line)) byLine.set(line, title);
  }
  return byLine;
}
function parsePlayerData(html) {
  const start = html.search(/(?:var\s+)?player_\w+\s*=\s*\{/iu);
  if (start < 0) throw new Error("Player data is unavailable.");
  const brace = html.indexOf("{", start);
  const value = JSON.parse(balancedObject(html, brace));
  if (!isObject(value)) throw new Error("Player data is invalid.");
  return value;
}
async function resolvePlayerUrl(player, playPage) {
  const raw = text(player.url);
  const encrypt = Number(player.encrypt ?? 0);
  const decoded = encrypt === 2 ? legacyDecode(Buffer.from(raw, "base64").toString("utf8")) : encrypt === 1 ? legacyDecode(raw) : raw;
  if (safeMediaUrl(decoded)) return { url: decoded, referer: playPage };
  if (decoded === "") throw new Error("Playback address is unavailable.");
  const playerPage = `${playerBase}/yinhua/?url=${encodeURIComponent(decoded)}`;
  let decrypted;
  try {
    decrypted = decryptMcuePlayerHtml(await fetchText(playerPage, {
      attempts: mcueRequestAttempts,
      timeoutMs: mcueRequestTimeoutMs
    }));
  } catch {
    return raiseMcueResolutionFailure();
  }
  if (!safeMediaUrl(decrypted)) return raiseMcueResolutionFailure();
  return { url: decrypted, referer: playerPage };
}
function raiseMcueResolutionFailure() {
  const active = requireContext();
  active.log.warn("mcue_resolution_failed");
  active.errors?.raise("source_media_resolution_failed");
  throw new Error("External media resolver failed.");
}
function decryptMcuePlayerHtml(html) {
  const cipher = extractMcueCipher(html);
  const seed = buildMcueSeed(html);
  if (cipher === "" || seed === "") throw new Error("Player response is invalid.");
  const digest = createHash("md5").update(seed + playerSalt).digest("hex");
  const decipher = createDecipheriv("aes-128-cbc", Buffer.from(digest.slice(16)), Buffer.from(digest.slice(0, 16)));
  const decrypted = decipher.update(cipher, "base64", "utf8") + decipher.final("utf8");
  return decodeJsString(decrypted.trim().replace(/^(?:"|')|(?:"|')$/gu, ""));
}
function buildMcueSeed(html) {
  const order = extractNowMetaId(html, (tag) => /^utf-8$/iu.test(attribute2(tag, "charset")));
  const values = extractNowMetaId(html, (tag) => /^viewport$/iu.test(attribute2(tag, "name")));
  if (order === "" || values === "" || order.length !== values.length) return "";
  return [...order].map((id, index) => ({ id: Number(id), value: values[index] ?? "" })).sort((left, right) => left.id - right.id).map((entry) => entry.value).join("");
}
function extractNowMetaId(html, predicate) {
  for (const match of html.matchAll(/<meta\b[^>]*>/giu)) {
    const tag = match[0];
    if (!predicate(tag)) continue;
    const id = attribute2(tag, "id");
    if (id.startsWith("now_")) return id.slice(4);
  }
  return "";
}
function extractMcueCipher(html) {
  return decodeJsString(/["']url["']\s*:\s*["']([^"']+)["']/iu.exec(html)?.[1] ?? "");
}
function balancedObject(value, start) {
  let depth = 0;
  let quote = "";
  let escaped = false;
  for (let index = start; index < value.length; index += 1) {
    const char = value[index] ?? "";
    if (quote !== "") {
      if (escaped) escaped = false;
      else if (char === "\\") escaped = true;
      else if (char === quote) quote = "";
      continue;
    }
    if (char === '"' || char === "'") {
      quote = char;
      continue;
    }
    if (char === "{") depth += 1;
    if (char === "}" && --depth === 0) return value.slice(start, index + 1);
  }
  throw new Error("Player data is incomplete.");
}
function contentId(id) {
  const value = /^video:(\d+)$/u.exec(id)?.[1];
  if (value === void 0) throw new Error("Content ID is invalid.");
  return value;
}
function parseChapterId(id, content) {
  const match = new RegExp(`^video:${content}:(\\d+):(\\d+)$`, "u").exec(id);
  if (match?.[1] === void 0 || match[2] === void 0) throw new Error("Chapter ID is invalid.");
  const line = Number(match[1]);
  const episode = Number(match[2]);
  if (!Number.isSafeInteger(line) || line < 1 || !Number.isSafeInteger(episode) || episode < 1) {
    throw new Error("Chapter ID is invalid.");
  }
  return { line: String(line), episode: String(episode) };
}
function searchPage(cursor) {
  if (cursor === null) return 1;
  const page = Number(/^search:(\d+)$/u.exec(cursor)?.[1]);
  if (!Number.isSafeInteger(page) || page < 2 || page > 50) throw new Error("Search cursor is invalid.");
  return page;
}
function parseCategory(html, id, title) {
  return categoryPanels(html, id, title).map((panel) => ({ ...panel, items: parseListing(panel.html) }));
}
function detailUrl(id) {
  return `${base}/v/${id}.html`;
}
function playUrl(id, line, episode) {
  return `${base}/p/${id}-${line}-${episode}.html`;
}
function safeMediaUrl(value) {
  try {
    const url = new URL(value);
    return ["https:", "http:"].includes(url.protocol) && url.username === "" && url.password === "";
  } catch {
    return false;
  }
}
function absolute(value) {
  if (value === null || value === "") return null;
  try {
    return new URL(decodeJsString(value), base).toString();
  } catch {
    return null;
  }
}
function proxyCover(value) {
  const url = absolute(value);
  if (url === null || !safeMediaUrl(url)) return null;
  return requireContext().resource.proxy({
    kind: "image",
    url,
    headers: { Accept: "image/*", Referer: `${base}/`, "User-Agent": pageHeaders["User-Agent"] },
    proxyMode: directProxyMode
  });
}
function cleanTitle(value) {
  const title = strip(value);
  if (title === "" || title.length > 120) return "";
  return /^(?:更新至第?\d+集|更新至\d+集|已?完结|全\d+集|完结|动漫|HD中字|HD|详情|立即播放|播放)$/u.test(title) ? "" : title;
}
function cleanEpisodeTitle(value, episode) {
  const title = strip(value);
  return title === "" || !/第|集|话|期/u.test(title) ? `第${String(episode).padStart(2, "0")}集` : title;
}
function projectLatestChapter(value) {
  const title = value === null ? "" : strip(value);
  if (title === "" || title.length > 256) return null;
  return frozen({ id: null, title, updatedAt: null, url: null });
}
function attribute2(value, name) {
  const quoted = new RegExp(`\\s${escape(name)}\\s*=\\s*(["'])(.*?)\\1`, "iu").exec(value);
  if (quoted?.[2] !== void 0) return decodeJsString(quoted[2]);
  return new RegExp(`\\s${escape(name)}\\s*=\\s*([^\\s>]+)`, "iu").exec(value)?.[1] ?? "";
}
function firstAttribute(html, pattern, name) {
  const match = pattern.exec(html);
  return match === null ? "" : attribute2(match[0], name);
}
function firstText(html, pattern) {
  return strip(pattern.exec(html)?.[1] ?? "");
}
function strip(value) {
  return decode(value.replace(/<script[\s\S]*?<\/script>/giu, "").replace(/<style[\s\S]*?<\/style>/giu, "").replace(/<[^>]+>/gu, " ").replace(/\s+/gu, " ")).trim();
}
function decode(value) {
  return value.replace(/&amp;/giu, "&").replace(/&quot;/giu, '"').replace(/&#(?:39|x27);/giu, "'").replace(/&lt;/giu, "<").replace(/&gt;/giu, ">").replace(/&nbsp;/giu, " ");
}
function decodeJsString(value) {
  return value.replace(/\\u([0-9a-f]{4})/giu, (_match, hex) => String.fromCharCode(Number.parseInt(hex, 16))).replace(/\\\//gu, "/").replace(/\\"/gu, '"').replace(/\\\\/gu, "\\");
}
function legacyDecode(value) {
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}
function uniqueText(values) {
  return [...new Set(values.filter((value) => value !== ""))];
}
function clamp(value) {
  return Math.max(1, Math.min(100, Math.floor(value)));
}
function text(value) {
  return typeof value === "string" ? value.trim() : typeof value === "number" ? String(value) : "";
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
export {
  activate,
  discover,
  getChapters,
  getContent,
  getDetail,
  search,
  searchSuggestions
};
