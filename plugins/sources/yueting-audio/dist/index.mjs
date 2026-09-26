import { createRequire as __mgreadCreateRequire } from 'node:module'; const require = __mgreadCreateRequire(import.meta.url);

// src/index.mts
import { createCipheriv, createDecipheriv, createHash, randomBytes } from "node:crypto";

// src/discovery-channels.ts
var channels = [
  {
    "id": "novel",
    "title": "小说",
    "category": "2",
    "classId": ""
  },
  {
    "id": "storytelling",
    "title": "评书",
    "category": "1",
    "classId": ""
  },
  {
    "id": "fantasy",
    "title": "玄幻奇幻",
    "category": "2",
    "classId": "46"
  },
  {
    "id": "wuxia",
    "title": "武侠小说",
    "category": "2",
    "classId": "11"
  },
  {
    "id": "romance",
    "title": "言情通俗",
    "category": "2",
    "classId": "19"
  },
  {
    "id": "type-21",
    "title": "相声小品",
    "category": "2",
    "classId": "21"
  },
  {
    "id": "thriller",
    "title": "恐怖惊悚",
    "category": "2",
    "classId": "14"
  },
  {
    "id": "type-17",
    "title": "官场商战",
    "category": "2",
    "classId": "17"
  },
  {
    "id": "history",
    "title": "历史军事",
    "category": "2",
    "classId": "15"
  },
  {
    "id": "type-9",
    "title": "百家讲坛",
    "category": "2",
    "classId": "9"
  },
  {
    "id": "type-16",
    "title": "刑侦反腐",
    "category": "2",
    "classId": "16"
  },
  {
    "id": "type-10",
    "title": "有声文学",
    "category": "2",
    "classId": "10"
  },
  {
    "id": "type-18",
    "title": "人物纪实",
    "category": "2",
    "classId": "18"
  },
  {
    "id": "radio-drama",
    "title": "广播剧",
    "category": "2",
    "classId": "36"
  },
  {
    "id": "type-22",
    "title": "英文读物",
    "category": "2",
    "classId": "22"
  },
  {
    "id": "type-23",
    "title": "轻音清心",
    "category": "2",
    "classId": "23"
  },
  {
    "id": "type-31",
    "title": "二人转",
    "category": "2",
    "classId": "31"
  },
  {
    "id": "type-33",
    "title": "健康养生",
    "category": "2",
    "classId": "33"
  },
  {
    "id": "type-34",
    "title": "综艺娱乐",
    "category": "2",
    "classId": "34"
  },
  {
    "id": "type-40",
    "title": "头条",
    "category": "2",
    "classId": "40"
  },
  {
    "id": "type-38",
    "title": "戏曲",
    "category": "2",
    "classId": "38"
  },
  {
    "id": "type-41",
    "title": "脱口秀",
    "category": "2",
    "classId": "41"
  },
  {
    "id": "type-42",
    "title": "商业财经",
    "category": "2",
    "classId": "42"
  },
  {
    "id": "type-43",
    "title": "亲子教育",
    "category": "2",
    "classId": "43"
  },
  {
    "id": "type-44",
    "title": "教育培训",
    "category": "2",
    "classId": "44"
  },
  {
    "id": "type-45",
    "title": "时尚生活",
    "category": "2",
    "classId": "45"
  },
  {
    "id": "children",
    "title": "童话寓言",
    "category": "2",
    "classId": "20"
  },
  {
    "id": "shan-tianfang",
    "title": "单田芳",
    "category": "1",
    "classId": "1"
  },
  {
    "id": "liu-lanfang",
    "title": "刘兰芳",
    "category": "1",
    "classId": "2"
  },
  {
    "id": "tian-lianyuan",
    "title": "田连元",
    "category": "1",
    "classId": "3"
  },
  {
    "id": "teller-4",
    "title": "袁阔成",
    "category": "1",
    "classId": "4"
  },
  {
    "id": "teller-5",
    "title": "连丽如",
    "category": "1",
    "classId": "5"
  },
  {
    "id": "teller-8",
    "title": "孙一",
    "category": "1",
    "classId": "8"
  },
  {
    "id": "teller-30",
    "title": "王子封臣",
    "category": "1",
    "classId": "30"
  },
  {
    "id": "teller-25",
    "title": "马长辉",
    "category": "1",
    "classId": "25"
  },
  {
    "id": "teller-26",
    "title": "昊儒书场",
    "category": "1",
    "classId": "26"
  },
  {
    "id": "teller-27",
    "title": "王军",
    "category": "1",
    "classId": "27"
  },
  {
    "id": "teller-28",
    "title": "王玥波",
    "category": "1",
    "classId": "28"
  },
  {
    "id": "teller-29",
    "title": "石连君",
    "category": "1",
    "classId": "29"
  },
  {
    "id": "teller-12",
    "title": "粤语评书",
    "category": "1",
    "classId": "12"
  },
  {
    "id": "teller-35",
    "title": "关永超",
    "category": "1",
    "classId": "35"
  },
  {
    "id": "teller-6",
    "title": "张少佐",
    "category": "1",
    "classId": "6"
  },
  {
    "id": "teller-7",
    "title": "田战义",
    "category": "1",
    "classId": "7"
  },
  {
    "id": "teller-13",
    "title": "其他评书",
    "category": "1",
    "classId": "13"
  }
];
var sorts = [["comprehensive", "综合排序"], ["popular", "播放最多"], ["updated", "最近更新"], ["new", "最新发布"]];
var statuses = [["all", "全部状态"], ["0", "已完结"], ["1", "连载中"]];

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

// src/index.mts
var catalogRoot = "https://json.tingyou8.vip/azybk/json_v1/";
var apiRoot = "https://tingyou.fm/api/";
var key = Buffer.from("ea9d9d4f9a983fe6f6382f29c7b46b8d6dc47abc6da36662e6ddff8c78902f65", "hex");
var appAgent = "zybk/1.0.6";
var webAgent = "Mozilla/5.0 (Linux; Android 13; Pixel 7 Build/TQ3A.230805.001; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/116.0.0.0 Mobile Safari/537.36";
var context;
async function activate(next) {
  context = next;
  next.log.info("source_activated");
}
async function search(request) {
  const query = request.query.trim();
  if (query === "") return frozen({ items: [], nextCursor: null, totalCount: 0 });
  const page = cursorPage(request.cursor, "search"), payload = encryptRequest(JSON.stringify({ keyword: query, page })), data = decryptObject(await postPayload("search", payload, { "User-Agent": appAgent })), values = records(data.results), items = summaries(values).slice(0, clamp(request.pageSize));
  return frozen({ items, nextCursor: values.length >= clamp(request.pageSize) ? `search:${page + 1}` : null, totalCount: nonNegative(data.total) });
}
async function searchSuggestions(_request) {
  return frozen({ items: [], nextCursor: null });
}
async function discover(request) {
  if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null) throw new Error("Initial discovery request is invalid.");
    const components = [];
    for (const id of ["novel", "storytelling"]) {
      const result = await discover({ target: "channel:" + id, cursor: null, collectionId: null, pageSize: Math.min(6, clamp(request.pageSize)) });
      if (result.kind === "document") components.push(...result.document.components);
    }
    for (const [category, title] of [["2", "全部听书分类"], ["1", "评书与主播"]]) {
      components.push({ type: "section", id: "yueting-channels-" + category, title, subtitle: null, icon: "explore", children: [{ type: "categoryCollection", id: "yueting-channel-list-" + category, layout: "chips", categories: channels.filter((channel2) => channel2.category === category).map((channel2) => ({ id: channel2.id, title: channel2.title, target: "channel:" + channel2.id, count: null, url: null, icon: "audio" })) }] });
    }
    return { kind: "document", document: { components } };
  }
  const match = /^channel:([a-z0-9-]+)(?::sort:([a-z]+):status:(all|0|1))?$/u.exec(request.target);
  const channel = channels.find((value) => value.id === match?.[1]), sort = match?.[2] ?? "comprehensive", status = match?.[3] ?? "all";
  if (!channel || !sorts.some(([id]) => id === sort)) throw new Error("Discovery target is invalid.");
  const suffix = sort === "comprehensive" && status === "all" ? "" : ":" + sort + ":" + status;
  const collectionId = "yueting:" + channel.id + suffix;
  if (request.collectionId !== null && request.collectionId !== collectionId) throw new Error("Discovery collection is invalid.");
  let { page, offset } = position(request.cursor, request.target);
  const values = [];
  let continuation = null;
  for (let scan = 0; scan < 5; scan++) {
    const prefix = channel.classId === "" ? "categories/" + channel.category : "types/" + channel.classId;
    const data = decryptObject(await getPayload(prefix + "/" + sort + "/p" + page));
    const raw = records(first(data.data, data.results, data));
    while (offset < raw.length && values.length < clamp(request.pageSize)) {
      const value = raw[offset++];
      if (status !== "all" && String(value.status) !== status) continue;
      values.push(...summaries([value]));
    }
    const pages = nonNegative(data.pages), more = raw.length > 0 && (pages === null || page < pages);
    continuation = offset < raw.length ? { target: request.target, cursor: request.target + ":" + page + ":" + offset } : more && page < 1e4 ? { target: request.target, cursor: request.target + ":" + (page + 1) + ":0" } : null;
    if (values.length >= clamp(request.pageSize) || !continuation) break;
    page++;
    offset = 0;
  }
  const items = values.map((content) => ({ content, rank: null, metric: null, recommendation: null }));
  const filters = [{ type: "categoryCollection", id: collectionId + ":sorts", layout: "chips", categories: sorts.map(([id, title]) => ({ id, title, target: "channel:" + channel.id + ":sort:" + id + ":status:" + status, count: null, url: null, icon: "audio" })) }, { type: "categoryCollection", id: collectionId + ":statuses", layout: "chips", categories: statuses.map(([id, title]) => ({ id, title, target: "channel:" + channel.id + ":sort:" + sort + ":status:" + id, count: null, url: null, icon: id === "0" ? "completed" : "audio" })) }];
  if (request.collectionId !== null) return { kind: "append", collectionId, items, continuation };
  return { kind: "document", document: { components: [{ type: "section", id: collectionId + ":section", title: channel.title, subtitle: null, icon: "audio", children: [{ type: "contentCollection", id: collectionId, layout: "coverGrid", items, continuation }, ...filters] }] } };
}
async function getDetail(request) {
  const id = contentId(request.id), data = decryptObject(await getPayload(`album_info/${encodeURIComponent(id)}`)), item = summary(data, id);
  return frozen({ ...item, aliases: [], catalogUrl: `${catalogRoot}album_chapters/${encodeURIComponent(id)}` });
}
async function getChapters(request) {
  const id = contentId(request.id), data = decryptObject(await getPayload(`album_chapters/${encodeURIComponent(id)}`)), items = records(data.chapters).map((value, index) => chapter(id, value, index)).filter(notNull);
  return frozen({ items, groups: items.length === 0 ? [] : [frozen({ id: `group:${id}:main`, title: "节目", order: 0, episodes: items })] });
}
async function getContent(request) {
  const albumId = contentId(request.id), chapterIndex = chapterNative(request.chapterId, albumId), dfp = makeDfp(), cookieHeaders = { "User-Agent": webAgent, Cookie: `dfp=${dfp}` };
  await requestText(new URL("me", apiRoot).toString(), { method: "POST", headers: cookieHeaders, body: "" });
  const payload = encryptRequest(JSON.stringify({ album_id: numericId(albumId), chapter_idx: numericId(chapterIndex) })), data = decryptObject(await postPayload("play_token", payload, cookieHeaders)), upstream = text(data.play_url);
  if (!safeUrl(upstream)) throw new Error("Audio address is unavailable.");
  const mediaHeaders = { Referer: "https://tingyou.fm/", "User-Agent": webAgent };
  return frozen({ chapterId: request.chapterId, contentKind: "audio", title: nullable(data.title), updatedAt: null, text: null, pages: [], media: { url: requireContext().resource.proxy({ kind: "audio", url: upstream, headers: mediaHeaders }), resourceType: "audio", resourcePolicy: "sessionOnly", expiresAt: null, mimeType: /\.m4a(?:$|[?#])/iu.test(upstream) ? "audio/mp4" : "audio/mpeg", headers: mediaHeaders } });
}
async function getPayload(path) {
  const raw = await requestText(new URL(path, catalogRoot).toString(), { headers: { "User-Agent": appAgent } }), value = parseJson(raw);
  return payloadOf(value);
}
async function postPayload(path, body, headers) {
  const raw = await requestText(new URL(path, apiRoot).toString(), { method: "POST", headers, body }), value = parseJson(raw);
  return payloadOf(value);
}
async function requestText(url, init) {
  const response = await requireContext().http.fetch(url, init);
  if (!response.ok) throw new Error("Source request failed.");
  return await response.text();
}
function payloadOf(value) {
  if (isObject(value)) {
    const payload = text(value.payload);
    if (payload !== "") return payload;
  }
  const raw = text(value);
  if (raw !== "") return raw;
  throw new Error("Encrypted payload is missing.");
}
function encryptRequest(plain) {
  const iv = randomBytes(12), cipher = createCipheriv("aes-256-gcm", key, iv), encrypted = Buffer.concat([cipher.update(plain, "utf8"), cipher.final()]), tag = cipher.getAuthTag();
  return Buffer.concat([Buffer.from([1]), iv, encrypted, tag]).toString("hex");
}
function decryptObject(payload) {
  const bytes = Buffer.from(payload.replaceAll(/\s/gu, ""), "hex");
  if (bytes.length < 41) throw new Error("Encrypted payload is invalid.");
  const version = bytes[0], nonce = bytes.subarray(1, 25), raw = bytes.subarray(25), body = version === 2 ? Buffer.from(raw).reverse() : raw, ciphertext = body.subarray(0, -16), tag = body.subarray(-16), subkey = hchacha20(key, nonce.subarray(0, 16)), nonce12 = Buffer.concat([Buffer.alloc(4), nonce.subarray(16, 24)]), decipher = createDecipheriv("chacha20-poly1305", subkey, nonce12, { authTagLength: 16 });
  decipher.setAuthTag(tag);
  const plain = Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString("utf8");
  const value = parseJson(plain);
  if (!isObject(value)) throw new Error("Source response is invalid.");
  return value;
}
function hchacha20(sourceKey, nonce) {
  const state = new Uint32Array(16), constants = Buffer.from("expand 32-byte k");
  for (let index = 0; index < 4; index += 1) state[index] = constants.readUInt32LE(index * 4);
  for (let index = 0; index < 8; index += 1) state[index + 4] = sourceKey.readUInt32LE(index * 4);
  for (let index = 0; index < 4; index += 1) state[index + 12] = nonce.readUInt32LE(index * 4);
  for (let round = 0; round < 10; round += 1) {
    quarter(state, 0, 4, 8, 12);
    quarter(state, 1, 5, 9, 13);
    quarter(state, 2, 6, 10, 14);
    quarter(state, 3, 7, 11, 15);
    quarter(state, 0, 5, 10, 15);
    quarter(state, 1, 6, 11, 12);
    quarter(state, 2, 7, 8, 13);
    quarter(state, 3, 4, 9, 14);
  }
  const output = Buffer.alloc(32), positions = [0, 1, 2, 3, 12, 13, 14, 15];
  positions.forEach((position2, index) => output.writeUInt32LE(state[position2] ?? 0, index * 4));
  return output;
}
function quarter(state, a, b, c, d) {
  state[a] = add(state[a], state[b]);
  state[d] = rotate((state[d] ?? 0) ^ (state[a] ?? 0), 16);
  state[c] = add(state[c], state[d]);
  state[b] = rotate((state[b] ?? 0) ^ (state[c] ?? 0), 12);
  state[a] = add(state[a], state[b]);
  state[d] = rotate((state[d] ?? 0) ^ (state[a] ?? 0), 8);
  state[c] = add(state[c], state[d]);
  state[b] = rotate((state[b] ?? 0) ^ (state[c] ?? 0), 7);
}
function add(a, b) {
  return (a ?? 0) + (b ?? 0) >>> 0;
}
function rotate(value, bits) {
  return (value << bits | value >>> 32 - bits) >>> 0;
}
function makeDfp() {
  const date = new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Shanghai", year: "numeric", month: "2-digit", day: "2-digit" }).format(/* @__PURE__ */ new Date()).replaceAll("-", ""), dailyKey = createHash("sha256").update(`fa317cd29b|${date}`).digest().subarray(0, 16), plain = `1a60ec86|212b95ee|4ec312a9||${webAgent}|Asia/Shanghai`, cipher = createCipheriv("sm4-ecb", dailyKey, null), encrypted = Buffer.concat([cipher.update(plain, "utf8"), cipher.final()]);
  return `f-${Number(date).toString(36)}:f-${encrypted.toString("base64")}`;
}
function summaries(values) {
  const result = /* @__PURE__ */ new Map();
  for (const value of values) {
    const id = sourceId(first(value.id, value.album_id));
    if (id !== null && text(value.title) !== "") result.set(id, summary(value, id));
  }
  return [...result.values()];
}
function summary(value, id) {
  const encoded = sourceId(id);
  if (encoded === null) throw new Error("Album ID is invalid.");
  const cover = text(first(value.cover_url, value.cover));
  return frozen({ id: `album:${encoded}`, title: text(value.title) || id, contentKind: "audio", coverOrientation: "portrait", author: nullable(first(value.teller, value.author)), url: `${catalogRoot}album_info/${encodeURIComponent(id)}`, coverUrl: proxyImage(cover), description: nullable(first(value.intro, value.description)), language: "zh-CN", status: value.status === 0 ? "completed" : value.status === 1 ? "ongoing" : "unknown", access: "unknown", wordCount: null, chapterCount: nonNegative(first(value.chapter_count, value.chapterCount, value.count)), publishedAt: null, updatedAt: null, latestChapter: nullable(value.latest_chapter_title) === null ? null : { id: `album:${id}:latest`, title: text(value.latest_chapter_title), url: null, updatedAt: null }, categories: stringList(first(value.cat, value.category)), tags: [], attributes: [] });
}
function chapter(albumId, value, index) {
  const native = sourceId(first(value.index, value.chapter_idx, value.id));
  if (native === null) return null;
  return frozen({ id: `album:${albumId}:${native}`, title: text(value.title) || `第 ${index + 1} 集`, order: index, url: null, volumeTitle: "节目", wordCount: null, updatedAt: null, isLocked: false, attributes: [] });
}
function sourceId(value) {
  const id = text(value);
  return /^\d+$/u.test(id) ? id : null;
}
function numericId(value) {
  const result = Number(value);
  return Number.isSafeInteger(result) ? result : value;
}
function contentId(id) {
  const value = /^album:(\d+)$/u.exec(id)?.[1];
  if (value === void 0) throw new Error("Content ID is invalid.");
  return value;
}
function chapterNative(id, albumId) {
  const value = new RegExp(`^album:${albumId}:(\\d+)$`, "u").exec(id)?.[1];
  if (value === void 0) throw new Error("Chapter ID is invalid.");
  return value;
}
function proxyImage(value) {
  if (!safeUrl(value)) return null;
  return requireContext().resource.proxy({ kind: "image", url: value, headers: { Referer: "https://tingyou.fm/" } });
}
function safeUrl(value) {
  try {
    const url = new URL(value);
    return (url.protocol === "https:" || url.protocol === "http:") && url.username === "" && url.password === "";
  } catch {
    return false;
  }
}
function cursorPage(cursor, target) {
  if (cursor === null) return 1;
  const raw = cursor.startsWith(`${target}:`) ? cursor.slice(target.length + 1) : "", page = Number(raw);
  if (!Number.isSafeInteger(page) || page < 2 || page > 1e3) throw new Error("Cursor is invalid.");
  return page;
}
function clamp(value) {
  return Math.max(1, Math.min(50, Math.floor(value)));
}
function nonNegative(value) {
  const result = Number(value);
  return Number.isSafeInteger(result) && result >= 0 ? result : null;
}
function stringList(value) {
  if (Array.isArray(value)) return value.map(text).filter(Boolean).slice(0, 32);
  const raw = text(value);
  return raw === "" ? [] : raw.split(/[,，/]/u).map((part) => part.trim()).filter(Boolean).slice(0, 32);
}
function parseJson(raw) {
  try {
    return JSON.parse(raw);
  } catch {
    throw new Error("Source response is invalid.");
  }
}
function first(...values) {
  return values.find((value) => value !== null && value !== void 0 && value !== "") ?? "";
}
function records(value) {
  return Array.isArray(value) ? value.filter(isObject) : [];
}
function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
function text(value) {
  return typeof value === "string" ? value.trim() : typeof value === "number" || typeof value === "bigint" ? String(value) : "";
}
function nullable(value) {
  const result = text(value);
  return result === "" ? null : result;
}
function notNull(value) {
  return value !== null;
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
