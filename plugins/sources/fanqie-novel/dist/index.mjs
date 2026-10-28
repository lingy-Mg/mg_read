import { createRequire as __mgreadCreateRequire } from 'node:module'; const require = __mgreadCreateRequire(import.meta.url);

// src/index.mts
var NOVEL_HOST = "https://novel.snssdk.com";
var WEB_HOST = "https://fanqienovel.com";
var LOGIN_URL = `${WEB_HOST}/`;
var USER_INFO_URL = `${WEB_HOST}/api/user/info/v2`;
var BOOKSHELF_URL = `${WEB_HOST}/reading/bookapi/bookshelf/info/v:version/?aid=1967&iid=0&version_code=57700&update_version_code=57700`;
var BROWSER_SESSION_KEY = "fanqie-webview";
var BOOK_HOST = "https://fq-book.netsite.cc";
var CONTENT_HOSTS = ["https://gofq.52dns.cc", "https://pyfq.52dns.cc", BOOK_HOST];
var USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36";
var HEADERS = {
  "User-Agent": USER_AGENT,
  Accept: "application/json, text/plain, */*"
};
var WEB_HEADERS = {
  "User-Agent": USER_AGENT,
  Accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
  "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8"
};
var COVER_HEADERS = {
  Accept: "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8",
  Referer: `${WEB_HOST}/`,
  "User-Agent": USER_AGENT
};
var CHANNELS = [
  ["1", "都市", 1],
  ["2", "都市生活", 1],
  ["7", "玄幻", 1],
  ["8", "科幻", 1],
  ["10", "悬疑", 1],
  ["11", "乡村", 1],
  ["12", "仙侠", 1],
  ["13", "历史", 1],
  ["14", "游戏", 1],
  ["15", "奇幻", 1],
  ["16", "军事", 1],
  ["17", "灵异", 1],
  ["18", "同人", 1],
  ["19", "末世", 1],
  ["20", "轻小说", 1],
  ["21", "其他", 1],
  ["22", "古代言情", 2],
  ["23", "现代言情", 2],
  ["24", "青春校园", 2],
  ["25", "纯爱", 2],
  ["26", "幻想言情", 2],
  ["27", "悬疑推理", 2],
  ["28", "武侠", 2],
  ["29", "短篇", 1],
  ["30", "全本", 1]
];
var context;
var pageQueue = Promise.resolve();
async function activate(next) {
  context = next;
  pageQueue = Promise.resolve();
  next.log.info("source_activated");
}
async function search(request) {
  const query = clean(request.query);
  if (!query) return frozen({ items: [], nextCursor: null, totalCount: 0 });
  const page = cursorPage(request.cursor, "search");
  const pageSize = clamp(request.pageSize);
  const urls = [
    `${BOOK_HOST}/search?query=${encodeURIComponent(query)}&page=${page}`,
    `${NOVEL_HOST}/api/novel/channel/homepage/search/search/v2/?device_platform=android&parent_enterfrom=novel_channel_search.tab.&offset=${(page - 1) * pageSize}&limit=${pageSize}&aid=1967&q=${encodeURIComponent(query)}`
  ];
  for (const url of urls) {
    try {
      const data = object((await getJson(url, HEADERS)).data);
      const items = parseSearchResults(data).slice(0, pageSize);
      if (items.length > 0 || url === urls[urls.length - 1]) {
        const hasMore = booleanValue(data.has_more) || items.length >= pageSize;
        return frozen({ items: items.map(summary).filter(notNull), nextCursor: hasMore ? `search:${page + 1}` : null, totalCount: null });
      }
    } catch {
    }
  }
  return frozen({ items: [], nextCursor: null, totalCount: null });
}
async function searchSuggestions(_request) {
  return frozen({ items: [], nextCursor: null });
}
async function discover(request) {
  if (request.target === null) {
    const account = accountSection(await readHomeUserSnapshot());
    return frozen({
      kind: "document",
      document: {
        components: [account, {
          type: "section",
          id: "fanqie-channels",
          title: "番茄小说",
          subtitle: "公开分类",
          icon: "book",
          children: [{
            type: "categoryCollection",
            id: "fanqie-channel-list",
            layout: "chips",
            categories: CHANNELS.map(([id, title]) => ({ id, title, target: `channel:${id}`, count: null, url: null, icon: "book" }))
          }]
        }]
      }
    });
  }
  if (request.target === "login") return openLogin();
  if (request.target === "bookshelf") return openBookshelf(request);
  const channel = CHANNELS.find(([id]) => request.target === `channel:${id}`);
  if (!channel) throw new Error("Discovery target is invalid.");
  const page = cursorPage(request.cursor, request.target);
  const pageSize = clamp(request.pageSize);
  const url = `${NOVEL_HOST}/api/novel/channel/homepage/new_category/book_list/v1/?parent_enterfrom=novel_channel_category.tab.&aid=1967&offset=${(page - 1) * pageSize}&limit=${pageSize}&category_id=${channel[0]}&gender=${channel[2]}`;
  const data = object((await getJson(url, HEADERS)).data);
  const values = records(data.data).map(summary).filter(notNull).slice(0, pageSize);
  const collectionId = `fanqie:${channel[0]}`;
  const items = values.map((content) => frozen({ content, rank: null, metric: null, recommendation: null }));
  const continuation = values.length >= pageSize ? frozen({ target: request.target, cursor: `${request.target}:${page + 1}` }) : null;
  if (request.collectionId !== null) {
    if (request.collectionId !== collectionId) throw new Error("Discovery collection is invalid.");
    return frozen({ kind: "append", collectionId, items, continuation });
  }
  return frozen({
    kind: "document",
    document: { components: [{
      type: "section",
      id: `${collectionId}:section`,
      title: channel[1],
      subtitle: null,
      icon: "book",
      children: [{ type: "contentCollection", id: collectionId, layout: "coverGrid", items, continuation }]
    }] }
  });
}
async function openLogin() {
  await withPage(async (page) => {
    await page.navigate(LOGIN_URL, { timeoutMs: 45e3 });
    await page.show({ timeoutMs: 15e3 });
  });
  requireContext().log.info("login_page_opened");
  return statusDocument("番茄网页登录已打开", "请在官方 WebView 中完成登录，再返回发现主页刷新账号资料和书架入口。");
}
async function openBookshelf(request) {
  const snapshot = await readBookshelfSnapshot();
  if (snapshot.status === "loggedOut") return statusDocument("番茄未登录", "请先使用“登录番茄小说”在官方 WebView 中完成登录。");
  if (snapshot.status !== "loggedIn") return statusDocument("登录状态无法确认", "番茄书架接口没有返回明确的登录状态，请先在官方 WebView 中完成登录，然后重试。");
  const offset = bookshelfOffset(request.cursor);
  const pageSize = clamp(request.pageSize);
  const ids = snapshot.bookIds.slice(offset, offset + pageSize);
  const details = (await Promise.all(ids.map(async (bookId) => {
    try {
      return await getDetail({ id: `novel:${bookId}` });
    } catch {
      requireContext().log.warn(`bookshelf_detail_failed:${bookId}`);
      return null;
    }
  }))).filter(notNull);
  const collectionId = "fanqie:bookshelf";
  const nextOffset = offset + ids.length;
  const continuation = nextOffset < snapshot.bookIds.length ? frozen({ target: "bookshelf", cursor: `bookshelf:${nextOffset}` }) : null;
  const items = details.map((content) => frozen({ content, rank: null, metric: null, recommendation: null }));
  if (request.collectionId !== null) {
    if (request.collectionId !== collectionId) throw new Error("Discovery collection is invalid.");
    return frozen({ kind: "append", collectionId, items, continuation });
  }
  return frozen({
    kind: "document",
    document: { components: [{
      type: "section",
      id: "fanqie-bookshelf:section",
      title: "番茄书架",
      subtitle: `已读取 ${snapshot.bookIds.length} 本书的 ID，并通过来源接口加载详情。`,
      icon: "books",
      children: [{ type: "contentCollection", id: collectionId, layout: "coverGrid", items, continuation }]
    }] }
  });
}
async function readUserSnapshot() {
  const response = await requestBrowserJson(USER_INFO_URL, 8e3);
  const status = loginState(response.code);
  if (status !== "loggedIn" || response.data === null) return { status, profile: null };
  const data = response.data;
  return {
    status,
    profile: {
      name: clean(text(data.name)).slice(0, 80),
      id: text(data.id).slice(0, 80),
      description: clean(text(data.desc)).slice(0, 240),
      avatar: text(data.avatar)
    }
  };
}
async function readHomeUserSnapshot() {
  try {
    return await readUserSnapshot();
  } catch {
    requireContext().log.warn("account_status_unavailable");
    return { status: "unknown", profile: null };
  }
}
async function readBookshelfSnapshot() {
  const response = await requestBrowserJson(BOOKSHELF_URL);
  if (response.code !== 0) return { status: loginState(response.code), bookIds: [] };
  const data = isObject(response.data) ? response.data : {};
  const shelf = Array.isArray(data.book_shelf_info) ? data.book_shelf_info : [];
  const bookIds = [...new Set(shelf.flatMap((entry) => {
    if (!isObject(entry)) return [];
    const bookId = text(entry.book_id);
    return /^\d+$/u.test(bookId) ? [bookId] : [];
  }))];
  return { status: "loggedIn", bookIds };
}
function loginState(code) {
  if (code === 0) return "loggedIn";
  if (code === -1 || code === 101119) return "loggedOut";
  return "unknown";
}
async function requestBrowserJson(url, timeoutMs = 3e4) {
  const raw = await requireContext().browser.sessionV1.request({
    version: 1,
    sessionKey: BROWSER_SESSION_KEY,
    url,
    method: "GET",
    headers: { Accept: "application/json, text/plain, */*" },
    body: null,
    interaction: "silent",
    presentation: "hidden",
    transport: "http",
    timeoutMs,
    maxResponseBytes: 2 * 1024 * 1024
  });
  if (!isObject(raw) || typeof raw.status !== "number" || raw.status < 200 || raw.status >= 400 || typeof raw.body !== "string") {
    return { code: null, data: null };
  }
  try {
    const value = JSON.parse(raw.body);
    if (!isObject(value)) return { code: null, data: null };
    const code = typeof value.code === "number" ? value.code : typeof value.code === "string" ? Number(value.code) : null;
    return { code: Number.isSafeInteger(code) ? code : null, data: isObject(value.data) ? value.data : null };
  } catch {
    return { code: null, data: null };
  }
}
function statusDocument(title, subtitle) {
  return frozen({
    kind: "document",
    document: { components: [{ type: "section", id: `fanqie-status:${title}`, title, subtitle, icon: "books", children: [] }] }
  });
}
function accountSection(snapshot) {
  const loggedIn = snapshot.status === "loggedIn";
  const title = loggedIn ? "番茄已登录" : snapshot.status === "loggedOut" ? "番茄未登录" : "登录状态待确认";
  const profile = snapshot.profile;
  const avatar = profile?.avatar && safeUrl(profile.avatar) ? requireContext().resource.proxy({ kind: "image", url: profile.avatar, headers: COVER_HEADERS }) : null;
  const actions = loggedIn ? [
    { id: "bookshelf", title: "查看番茄书架", target: "bookshelf", count: null, url: null, icon: "books" },
    { id: "login", title: "打开番茄小说", target: "login", count: null, url: null, icon: "globe" }
  ] : [
    { id: "login", title: "登录番茄小说", target: "login", count: null, url: null, icon: "globe" }
  ];
  return frozen({
    type: "section",
    id: "fanqie-account",
    title: "我的番茄账号",
    subtitle: null,
    icon: "books",
    children: [{
      type: "profileCard",
      id: "fanqie-account-profile",
      name: loggedIn ? profile?.name || "番茄用户" : title,
      subtitle: loggedIn ? profile?.description || "已连接番茄小说账号" : snapshot.status === "loggedOut" ? "登录后可查看个人资料和官方书架" : "当前无法确认账号状态，请刷新重试",
      badge: loggedIn ? "已登录" : snapshot.status === "loggedOut" ? "未登录" : "待确认",
      avatarUrl: avatar,
      details: loggedIn && profile?.id ? [{ label: "用户 ID", value: profile.id }] : []
    }, {
      type: "categoryCollection",
      id: "fanqie-account-actions",
      layout: "chips",
      categories: actions
    }]
  });
}
function bookshelfOffset(cursor) {
  if (cursor === null) return 0;
  const value = Number(cursor.startsWith("bookshelf:") ? cursor.slice("bookshelf:".length) : "");
  if (!Number.isSafeInteger(value) || value < 1) throw new Error("Cursor is invalid.");
  return value;
}
async function getDetail(request) {
  const id = contentId(request.id);
  try {
    const data = findBook(await getJson(`${BOOK_HOST}/info?book_id=${id}`, HEADERS));
    let item = summary({ ...data, book_id: id });
    if (item) {
      if (!item.coverUrl) {
        try {
          const web = parseWebDetail(await getText(`${WEB_HOST}/page/${id}`, WEB_HEADERS), id);
          if (web?.coverUrl) item = frozen({ ...item, coverUrl: web.coverUrl });
        } catch {
          requireContext().log.warn(`detail_cover_unavailable:${id}`);
        }
      }
      return frozen({ ...item, description: clean(text(data.abstract || data.intro)) || null, chapterCount: number(data.chapter_number) || null, latestChapter: latestChapter(data, id), aliases: [], catalogUrl: `${WEB_HOST}/api/reader/directory/detail?bookId=${id}` });
    }
  } catch {
  }
  const fallback = parseWebDetail(await getText(`${WEB_HOST}/page/${id}`, WEB_HEADERS), id);
  if (!fallback) throw new Error("Book detail is unavailable.");
  return frozen({ ...fallback, aliases: [], catalogUrl: `${WEB_HOST}/api/reader/directory/detail?bookId=${id}` });
}
async function getChapters(request) {
  const id = contentId(request.id);
  const data = object((await getJson(`${WEB_HOST}/api/reader/directory/detail?bookId=${id}`, HEADERS)).data);
  const items = [];
  const volumes = Array.isArray(data.chapterListWithVolume) ? data.chapterListWithVolume : [];
  for (const [volumeIndex, raw] of volumes.entries()) {
    for (const chapter of records(raw)) {
      const itemId = text(chapter.itemId || chapter.item_id);
      if (!/^\d+$/u.test(itemId)) continue;
      items.push({ id: `novel:${id}:${itemId}`, title: clean(text(chapter.title)) || `第${items.length + 1}章`, order: items.length, url: null, volumeTitle: `第${volumeIndex + 1}卷`, wordCount: null, updatedAt: timestamp(chapter.firstPassTime || chapter.first_pass_time), isLocked: false, attributes: [] });
    }
  }
  if (items.length === 0) {
    for (const raw of Array.isArray(data.allItemIds) ? data.allItemIds : []) {
      const itemId = text(raw);
      if (/^\d+$/u.test(itemId)) items.push({ id: `novel:${id}:${itemId}`, title: `第${items.length + 1}章`, order: items.length, url: null, volumeTitle: null, wordCount: null, updatedAt: null, isLocked: false, attributes: [] });
    }
  }
  const groups = [...new Set(items.map((item) => item.volumeTitle).filter((value) => value !== null))].map((title, index) => frozen({ id: `group:${id}:${index}`, title, order: index, episodes: items.filter((item) => item.volumeTitle === title).map((item, order) => frozen({ ...item, order })) }));
  return frozen({ items: Object.freeze(items.map(frozen)), groups });
}
async function getContent(request) {
  const id = contentId(request.id);
  const itemId = chapterNative(request.chapterId, id);
  for (const host of CONTENT_HOSTS) {
    try {
      const candidate = findContent(await getJson(`${host}/content?item_id=${itemId}`, HEADERS));
      const value = candidate ? formatContent(candidate) : "";
      if (value) return frozen({ chapterId: request.chapterId, contentKind: "novel", title: null, updatedAt: null, text: value, pages: [], media: null });
    } catch {
    }
  }
  throw new Error("Chapter content is unavailable.");
}
async function getJson(url, headers) {
  const response = await requireContext().http.fetch(url, { headers });
  if (!response.ok) throw new Error("Source request failed.");
  let value;
  try {
    value = await response.json();
  } catch {
    throw new Error("Source response is invalid.");
  }
  if (!isObject(value)) throw new Error("Source response is invalid.");
  return value;
}
async function getText(url, headers) {
  const response = await requireContext().http.fetch(url, { headers });
  if (!response.ok) throw new Error("Source request failed.");
  return response.text();
}
function parseSearchResults(data) {
  const results = [];
  const seen = /* @__PURE__ */ new Set();
  const tabs = Array.isArray(data.search_tabs) ? data.search_tabs : [];
  for (const tab of tabs) {
    if (!isObject(tab) || !Array.isArray(tab.data)) continue;
    for (const entry of tab.data) {
      const books = isObject(entry) && entry.book_data !== void 0 ? recordsOrObjectValues(entry.book_data) : isObject(entry) && entry.book_info !== void 0 ? recordsOrObjectValues(entry.book_info) : [];
      addBooks(books, results, seen);
    }
  }
  if (results.length === 0) addBooks(recordsOrObjectValues(data.ret_data || data.book_data || data.book_info), results, seen);
  return results;
}
function addBooks(values, target, seen) {
  for (const value of values) {
    const nested = value.book_id || value.bookId ? [value] : value.book_data !== void 0 ? recordsOrObjectValues(value.book_data) : value.book_info !== void 0 ? recordsOrObjectValues(value.book_info) : [];
    for (const book of nested) {
      const id = text(book.book_id || book.bookId);
      if (!/^\d+$/u.test(id) || seen.has(id)) continue;
      seen.add(id);
      target.push(book);
    }
  }
}
function recordsOrObjectValues(value) {
  if (Array.isArray(value)) return value.filter(isObject);
  return isObject(value) ? Object.values(value).filter(isObject) : [];
}
function summary(value) {
  const id = text(value.book_id || value.bookId);
  const title = clean(text(value.book_name || value.title || value.name));
  if (!/^\d+$/u.test(id) || !title) return null;
  const cover = replaceCover(text(value.thumb_url || value.cover || value.cover_url));
  const statusCode = number(value.creation_status);
  const status = statusCode === 1 ? "completed" : statusCode === 4 ? "hiatus" : "ongoing";
  return frozen({
    id: `novel:${id}`,
    title,
    contentKind: "novel",
    coverOrientation: "portrait",
    author: clean(text(value.author)) || null,
    url: `${WEB_HOST}/page/${id}`,
    coverUrl: cover ? requireContext().resource.proxy({ kind: "image", url: cover, headers: COVER_HEADERS }) : null,
    description: clean(text(value.abstract || value.book_abstract_v2 || value.intro)) || null,
    language: "zh-CN",
    status,
    access: "free",
    wordCount: number(value.word_number) || null,
    chapterCount: number(value.chapter_number) || null,
    publishedAt: null,
    updatedAt: timestamp(value.last_update_time || value.update_time),
    latestChapter: null,
    categories: text(value.category) ? [clean(text(value.category))] : [],
    tags: text(value.tags) ? text(value.tags).split(",").map(clean).filter(Boolean) : [],
    attributes: []
  });
}
function findBook(root) {
  const queue = [root];
  const seen = /* @__PURE__ */ new Set();
  let selected;
  while (queue.length > 0) {
    const current = queue.shift();
    if (seen.has(current)) continue;
    seen.add(current);
    if (selected === void 0 && text(current.book_name || current.name)) selected = current;
    for (const value of Object.values(current)) if (isObject(value)) queue.push(value);
  }
  if (selected === void 0) return {};
  if (text(selected.thumb_url || selected.cover || selected.cover_url)) return selected;
  const cover = findCover(root);
  return cover === null ? selected : { ...selected, thumb_url: cover };
}
function findCover(root) {
  const queue = [root];
  const seen = /* @__PURE__ */ new Set();
  while (queue.length > 0) {
    const current = queue.shift();
    if (seen.has(current)) continue;
    seen.add(current);
    const cover = text(current.thumb_url || current.cover || current.cover_url);
    if (cover !== "") return cover;
    for (const value of Object.values(current)) if (isObject(value)) queue.push(value);
  }
  return null;
}
function latestChapter(value, bookId) {
  const itemId = text(value.last_chapter_item_id || value.last_item_id);
  const title = clean(text(value.last_chapter_title));
  return title ? { id: /^\d+$/u.test(itemId) ? `novel:${bookId}:${itemId}` : null, title, url: null, updatedAt: null } : null;
}
function parseWebDetail(html, id) {
  const name = parseWebTitle(text(readJsonLd(html, "headline") || readTag(html, "title")));
  if (!name) return null;
  const authorValue = readJsonLd(html, "author");
  const author = isObject(authorValue) ? text(authorValue.name) : Array.isArray(authorValue) && isObject(authorValue[0]) ? text(authorValue[0].name) : text(authorValue);
  const image = readJsonLd(html, "image");
  const cover = (Array.isArray(image) ? image.map(text).find(safeUrl) : text(image)) || readMeta(html, "og:image");
  return summary({ book_id: id, book_name: name, author, thumb_url: cover, abstract: readMeta(html, "description") });
}
function readJsonLd(html, key) {
  const match = /<script[^>]*type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/iu.exec(html);
  if (!match) return null;
  try {
    return JSON.parse(match[1] ?? "{}")[key];
  } catch {
    return null;
  }
}
function readMeta(html, property) {
  const pattern = new RegExp(`<meta[^>]+(?:name|property)=["']${escapeRegExp(property)}["'][^>]+content=["']([^"']*)["']`, "iu");
  return decode((pattern.exec(html)?.[1] ?? "").trim());
}
function readTag(html, tag) {
  return decode((new RegExp(`<${tag}[^>]*>([\\s\\S]*?)<\\/${tag}>`, "iu").exec(html)?.[1] ?? "").trim());
}
function parseWebTitle(value) {
  return clean(value.split("_")[0] ?? "").replace(/完整版在线免费阅读$/u, "").replace(/小说$/u, "").replace(/[《》]/gu, "").trim();
}
function findContent(root) {
  if (typeof root === "string") return root;
  if (Array.isArray(root)) for (const value of root) {
    const found = findContent(value);
    if (found) return found;
  }
  if (isObject(root)) {
    if (typeof root.content === "string" && root.content) return root.content;
    for (const value of Object.values(root)) {
      const found = findContent(value);
      if (found) return found;
    }
  }
  return "";
}
function formatContent(value) {
  const content = value.replace(/##收听有声版[\s\S]*$/u, "").replace(/<tt_keyword_ad[\s\S]*?<\/tt_keyword_ad>/giu, " ");
  if (!/<[^>]+>/u.test(content)) return plainText(content);
  const paragraphs = [];
  const block = /<p\b[^>]*>([\s\S]*?)<\/p>|<div\b[^>]*data-fanqie-type=["']image["'][^>]*>[\s\S]*?<\/div>/giu;
  for (const match of content.matchAll(block)) {
    const textValue = stripHtml(match[1] ?? "");
    if (textValue) paragraphs.push(textValue);
  }
  return paragraphs.length > 0 ? paragraphs.join("\n\n") : plainText(content);
}
function plainText(value) {
  const decoded = decode(value.replace(/<br\s*\/?\s*>/giu, "\n").replace(/<[^>]+>/gu, " "));
  return decoded.split(/\r?\n+/u).map((line) => line.replace(/^　+/u, "").trim()).filter(Boolean).join("\n\n");
}
function stripHtml(value) {
  return plainText(value);
}
function decode(value) {
  return value.replaceAll("&nbsp;", " ").replaceAll("&lt;", "<").replaceAll("&gt;", ">").replaceAll("&amp;", "&").replaceAll("&quot;", '"').replaceAll("&#39;", "'").replaceAll("&apos;", "'");
}
function replaceCover(value) {
  if (!safeUrl(value)) return "";
  const url = new URL(value);
  return `https://p6-novel.byteimg.com/origin${url.pathname.replace(/~.*$/u, "")}`;
}
function withPage(action) {
  const run = pageQueue.then(async () => action(await requireContext().webview.open({ visible: true, timeoutMs: 3e4 })));
  pageQueue = run.then(() => void 0, () => void 0);
  return run;
}
function contentId(id) {
  const value = /^novel:(\d+)$/u.exec(id)?.[1];
  if (!value) throw new Error("Content ID is invalid.");
  return value;
}
function chapterNative(id, bookId) {
  const value = new RegExp(`^novel:${bookId}:(\\d+)$`, "u").exec(id)?.[1];
  if (!value) throw new Error("Chapter ID is invalid.");
  return value;
}
function cursorPage(cursor, target) {
  if (cursor === null) return 1;
  const page = Number(cursor.startsWith(`${target}:`) ? cursor.slice(target.length + 1) : "");
  if (!Number.isSafeInteger(page) || page < 2) throw new Error("Cursor is invalid.");
  return page;
}
function timestamp(value) {
  const numeric = number(value);
  return numeric > 0 ? new Date(numeric < 1e12 ? numeric * 1e3 : numeric).toISOString() : null;
}
function clean(value) {
  return decode(value).replace(/<[^>]+>/gu, " ").replace(/\s+/gu, " ").trim();
}
function text(value) {
  return typeof value === "string" ? value.trim() : typeof value === "number" ? String(value) : "";
}
function number(value) {
  return typeof value === "number" && Number.isFinite(value) ? value : typeof value === "string" ? Number(value) || 0 : 0;
}
function booleanValue(value) {
  return value === true || value === 1 || value === "1" || value === "true";
}
function object(value) {
  return isObject(value) ? value : {};
}
function records(value) {
  return Array.isArray(value) ? value.filter(isObject) : [];
}
function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
function safeUrl(value) {
  try {
    return ["http:", "https:"].includes(new URL(value).protocol);
  } catch {
    return false;
  }
}
function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
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
  if (!context) throw new Error("Source is not activated.");
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
