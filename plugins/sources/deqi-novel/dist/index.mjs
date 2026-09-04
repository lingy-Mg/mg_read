const site = 'https://www.deqixs.cc', agent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36', headers = { 'User-Agent': agent, Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8', 'Accept-Language': 'zh-CN,zh;q=0.9', Referer: `${site}/` }, channels = [{ id: '0', title: '全部' }, { id: '1', title: '玄幻' }, { id: '2', title: '都市' }, { id: '3', title: '仙侠' }, { id: '4', title: '历史' }, { id: '5', title: '科幻' }, { id: '6', title: '诸天' }, { id: '7', title: '悬疑' }, { id: '8', title: '体育' }, { id: '9', title: '游戏' }, { id: '10', title: '综合' }];
let context;
const cache = new Map();
export async function activate(next) { context = next; cache.clear(); next.log.info('source_activated'); }
export async function search(request) { const query = request.query.trim(); if (query === '')
    return frozen({ items: [], nextCursor: null, totalCount: 0 }); const page = cursorPage(request.cursor, 'search'), url = `${site}/modules/article/search.php?searchkey=${encodeURIComponent(query)}&action=search&searchtype=articlename&page=${page}`, source = await get(url), values = parseBooks(source), single = values.length ? values : singleBook(source), items = single.map(summary).slice(0, clamp(request.pageSize)); return frozen({ items, nextCursor: items.length >= clamp(request.pageSize) ? `search:${page + 1}` : null, totalCount: null }); }
export async function searchSuggestions(_request) { return frozen({ items: [], nextCursor: null }); }
export async function discover(request) { if (request.target === null)
    return frozen({ kind: 'document', document: { components: [{ type: 'section', id: 'deqi-channels', title: '得奇小说网', subtitle: '免费小说分类', icon: 'book', children: [{ type: 'categoryCollection', id: 'deqi-channel-list', layout: 'chips', categories: channels.map(channel => ({ id: channel.id, title: channel.title, target: `channel:${channel.id}`, count: null, url: null, icon: 'book' })) }] }] } }); const channel = channels.find(value => request.target === `channel:${value.id}`); if (!channel)
    throw new Error('Discovery target is invalid.'); const page = cursorPage(request.cursor, request.target), size = clamp(request.pageSize), values = parseBooks(await get(`${site}/sort/${channel.id}/${page}.html`)), contents = values.map(summary).slice(0, size), collectionId = `deqi:${channel.id}`, items = contents.map(content => frozen({ content, rank: null, metric: null, recommendation: null })), continuation = values.length >= size ? frozen({ target: request.target, cursor: `channel:${channel.id}:${page + 1}` }) : null; if (request.collectionId !== null) {
    if (request.collectionId !== collectionId)
        throw new Error('Discovery collection is invalid.');
    return frozen({ kind: 'append', collectionId, items, continuation });
} return frozen({ kind: 'document', document: { components: [{ type: 'section', id: `${collectionId}:section`, title: channel.title, subtitle: null, icon: 'book', children: [{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation }] }] } }); }
export async function getDetail(request) { const id = contentId(request.id), source = await get(`${site}/modules/article/articleinfo.php?id=${id}`), book = detail(source, id); return frozen({ ...summary(book), aliases: [], catalogUrl: `${site}/books/${id}/` }); }
export async function getChapters(request) { const id = contentId(request.id), chapters = parseChapters(await get(`${site}/books/${id}/`), id), items = chapters.map((chapter, index) => frozen({ id: `book:${id}:${chapter.id}`, title: chapter.title, order: index, url: null, volumeTitle: null, wordCount: null, updatedAt: null, isLocked: false, attributes: [] })); return frozen({ items, groups: [] }); }
export async function getContent(request) { const id = contentId(request.id), chapter = chapterNative(request.chapterId, id), pageUrl = `${site}/books/${id}/${chapter}.html`, page = await get(pageUrl), script = await get(`${site}/scripts/chapter.js.php?aid=${id}&cid=${chapter}&referrer=${encodeURIComponent(pageUrl)}`, { ...headers, Referer: pageUrl, Accept: '*/*' }), token = script.match(/var chapterToken = '([^']+)'/u)?.[1], timestamp = script.match(/var timestamp = (\d+)/u)?.[1], nonce = script.match(/var nonce = '([^']+)'/u)?.[1]; if (!token || !timestamp || !nonce)
    throw new Error('Chapter token is unavailable.'); const api = `${site}/modules/article/ajax2.php?aid=${id}&cid=${chapter}&token=${encodeURIComponent(token)}&timestamp=${timestamp}&nonce=${encodeURIComponent(nonce)}`, raw = await get(api, { ...headers, Origin: site, Referer: pageUrl, 'X-Requested-With': 'XMLHttpRequest', Accept: 'application/json, text/javascript, */*; q=0.01' }, false); let value; try {
    value = JSON.parse(raw);
}
catch {
    throw new Error('Chapter response is invalid.');
} const data = isRecord(value) && isRecord(value.data) ? value.data : {}, html = text(data.content); if (Number(isRecord(value) ? value.status : 0) !== 1 || !html)
    throw new Error('Chapter content is unavailable.'); const content = cleanContent(html, page); return frozen({ chapterId: request.chapterId, contentKind: 'novel', title: chapterTitle(page), updatedAt: null, text: content, pages: [], media: null }); }
async function get(url, requestHeaders = headers, useCache = true) { if (useCache) {
    const hit = cache.get(url);
    if (hit)
        return hit;
} const response = await requireContext().http.fetch(url, { headers: requestHeaders }); if (!response.ok)
    throw new Error('Source request failed.'); const value = await response.text(); if (useCache)
    cache.set(url, value); return value; }
function parseBooks(source) { const result = new Map(); for (const match of source.matchAll(/<div\b[^>]*class="[^"]*bookbox[^"]*"[^>]*>([\s\S]*?)(?=<div\b[^>]*class="[^"]*bookbox|$)/gu)) {
    const block = match[1] ?? '', link = block.match(/<h4\b[^>]*class="[^"]*bookname[^"]*"[^>]*>[\s\S]*?<a[^>]*href="([^"]*\/books\/(\d+)\/)[^"]*"[^>]*>([\s\S]*?)<\/a>/u);
    if (!link)
        continue;
    const id = link[2] ?? '', title = clean(link[3] ?? '');
    if (!id || !title)
        continue;
    const author = clean(block.match(/<div\b[^>]*class="[^"]*author[^"]*"[^>]*>([\s\S]*?)<\/div>/u)?.[1] ?? '').replace(/^作者：/u, ''), latest = clean(block.match(/<div\b[^>]*class="[^"]*cat[^"]*"[^>]*>[\s\S]*?<a[^>]*>([\s\S]*?)<\/a>/u)?.[1] ?? '');
    result.set(id, { id, title, author, latest, category: '', cover: cover(id), description: '' });
} return [...result.values()]; }
function singleBook(source) { const title = meta(source, 'og:novel:book_name') || meta(source, 'og:title'), url = meta(source, 'og:novel:read_url'), id = url.match(/\/books\/(\d+)/u)?.[1]; return title && id ? [{ id, title, author: meta(source, 'og:novel:author'), latest: meta(source, 'og:novel:latest_chapter_name'), category: meta(source, 'og:novel:category'), cover: meta(source, 'og:image') || cover(id), description: '' }] : []; }
function detail(source, id) { return { id, title: meta(source, 'og:title') || clean(source.match(/<h1[^>]*class="[^"]*booktitle[^"]*"[^>]*>([^<]*)/u)?.[1] ?? '') || id, author: meta(source, 'og:novel:author'), latest: meta(source, 'og:novel:latest_chapter_name'), category: meta(source, 'og:novel:category'), cover: meta(source, 'og:image') || cover(id), description: clean(source.match(/<p[^>]*class="[^"]*bookintro[^"]*"[^>]*>([\s\S]*?)<\/p>/u)?.[1] ?? '') }; }
function parseChapters(source, id) { const result = new Map(), pattern = new RegExp(`<a\\s+href="[^"]*\\/books\\/${id}\\/(\\d+)\\.html"[^>]*>([^<]*)<\\/a>`, 'giu'); for (const match of source.matchAll(pattern)) {
    const chapter = match[1] ?? '', title = clean(match[2] ?? '');
    if (chapter && title && !['开始阅读', '加入书架', '推荐本书', 'TXT下载'].includes(title))
        result.set(chapter, { id: chapter, title });
} return [...result.values()].sort((a, b) => Number(a.id) - Number(b.id)); }
function summary(book) { return frozen({ id: `book:${book.id}`, title: book.title, contentKind: 'novel', coverOrientation: 'portrait', author: book.author || null, url: `${site}/books/${book.id}/`, coverUrl: proxyImage(book.cover), description: book.description || null, language: 'zh-CN', status: 'unknown', access: 'free', wordCount: null, chapterCount: null, publishedAt: null, updatedAt: null, latestChapter: book.latest ? { id: `book:${book.id}:latest`, title: book.latest, url: null, updatedAt: null } : null, categories: book.category ? [book.category] : [], tags: [], attributes: [] }); }
function meta(source, property) { const escaped = property.replaceAll(/[.*+?^${}()|[\]\\]/gu, '\\$&'); return decode(source.match(new RegExp(`<meta[^>]*property="${escaped}"[^>]*content="([^"]*)"`, 'iu'))?.[1] ?? ''); }
function cover(id) { return `${site}/files/article/image/${Math.floor(Number(id) / 1000)}/${id}/${id}s.jpg`; }
function cleanContent(html, page) { const heading = chapterTitle(page), plain = decode(html.replace(/^\s*<h[1-4][^>]*>[^<]*<\/h[1-4]>\s*(<br\s*\/?>\s*)*/iu, '').replaceAll(/<br\s*\/?>/giu, '\n').replaceAll(/<[^>]+>/gu, '')); return plain.replaceAll(/[\u200B\u200C\u200D\uFEFF]/gu, '').replaceAll(/\n{3,}/gu, '\n\n').trim().replace(new RegExp(`^${heading.replaceAll(/[.*+?^${}()|[\]\\]/gu, '\\$&')}\\s*`, 'u'), ''); }
function chapterTitle(page) { return clean(page.match(/<h1[^>]*class="[^"]*pt10[^"]*"[^>]*>\s*([^<]+)/u)?.[1] ?? page.match(/<li[^>]*class="[^"]*active[^"]*"[^>]*>([^<]+)<\/li>/u)?.[1] ?? ''); }
function clean(value) { return decode(value.replaceAll(/<[^>]+>/gu, ' ').replaceAll(/\s+/gu, ' ').trim()); }
function decode(value) { return value.replaceAll(/&nbsp;/giu, ' ').replaceAll(/&emsp;/giu, '    ').replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&amp;', '&').replaceAll('&quot;', '"').replaceAll('&#39;', "'"); }
function contentId(id) { const value = /^book:(\d+)$/u.exec(id)?.[1]; if (!value)
    throw new Error('Content ID is invalid.'); return value; }
function chapterNative(id, book) { const value = new RegExp(`^book:${book}:(\\d+)$`, 'u').exec(id)?.[1]; if (!value)
    throw new Error('Chapter ID is invalid.'); return value; }
function proxyImage(url) { return safeUrl(url) ? requireContext().resource.proxy({ kind: 'image', url, headers: { Referer: `${site}/` } }) : null; }
function safeUrl(value) { try {
    return ['http:', 'https:'].includes(new URL(value).protocol);
}
catch {
    return false;
} }
function cursorPage(cursor, target) { if (cursor === null)
    return 1; const page = Number(cursor.startsWith(`${target}:`) ? cursor.slice(target.length + 1) : ''); if (!Number.isSafeInteger(page) || page < 2)
    throw new Error('Cursor is invalid.'); return page; }
function isRecord(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function text(value) { return typeof value === 'string' ? value.trim() : ''; }
function clamp(value) { return Math.max(1, Math.min(50, Math.floor(value))); }
function frozen(value) { return Object.freeze(value); }
function requireContext() { if (!context)
    throw new Error('Source is not activated.'); return context; }
