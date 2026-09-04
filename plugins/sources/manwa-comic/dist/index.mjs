/**
 * 漫蛙漫画原生数据源。
 *
 * 职责：直接读取漫蛙公开 JSON 与漫画详情页，生成搜索、分类、目录和图片阅读数据。
 * 生命周期：activate 注入 Runtime；不保存登录态。
 * IO：页面与 API 走 ctx.http；封面和章节图片经 ctx.resource.proxy。
 * 稳定标识：漫画使用站点数字 ID，章节使用图片接口 cid 与分页号。
 */
import { load } from 'cheerio';
const base = 'https://manwamu.cc', headers = Object.freeze({ 'User-Agent': 'Mozilla/5.0 MgRead', Accept: 'text/html,application/json,*/*' }), categories = Object.freeze([['latest', '最新', 'comic'], ['ancient', '古风', 'gufeng'], ['fantasy', '玄幻', 'xuanhuan'], ['campus', '校园', 'xiaoyuan'], ['vip', 'VIP', 'vip']]);
let context;
export async function activate(next) { context = next; next.log.info('source_activated'); }
export async function search(request) { const query = request.query.trim(); if (query === '')
    return frozen({ items: [], nextCursor: null, totalCount: 0 }); const page = cursorPage(request.cursor, 'search'), size = clamp(request.pageSize), json = await fetchJson(`${base}/api/search?type=mh&page=${page}&pageSize=${size}&keyword=${encodeURIComponent(query)}`), data = object(json.data), items = records(data.list).map(apiSummary).filter(notNull), totalCount = nonNegative(first(data.total, data.totalCount)); return frozen({ items, nextCursor: totalCount !== null ? page * size < totalCount ? `search:${page + 1}` : null : items.length >= size ? `search:${page + 1}` : null, totalCount }); }
export async function searchSuggestions(_request) { return frozen({ items: [], nextCursor: null }); }
export async function discover(request) { if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null)
        throw new Error('Initial discovery request is invalid.');
    return frozen({ kind: 'document', document: { components: [{ type: 'section', id: 'manwa-categories', title: '漫蛙漫画', subtitle: '按分类浏览', icon: 'manga', children: [{ type: 'categoryCollection', id: 'manwa-category-list', layout: 'chips', categories: categories.map(([id, title]) => ({ id, title, target: `category:${id}`, count: null, url: null, icon: 'manga' })) }] }] } });
} const category = categories.find(([id]) => request.target === `category:${id}`); if (category === undefined)
    throw new Error('Discovery target is invalid.'); const page = cursorPage(request.cursor, request.target), size = clamp(request.pageSize), json = await fetchJson(`${base}/api/home?page=${page}&pageSize=${size}&type=${category[2]}&flag=true`), values = records(object(json.data)[`${category[2]}List`]).map(apiSummary).filter(notNull), collectionId = `manga:${category[0]}`, items = values.map(content => frozen({ content, rank: null, metric: null, recommendation: null })), continuation = values.length >= size ? frozen({ target: request.target, cursor: `${request.target}:${page + 1}` }) : null; if (request.collectionId !== null) {
    if (request.collectionId !== collectionId)
        throw new Error('Discovery collection is invalid.');
    return frozen({ kind: 'append', collectionId, items, continuation });
} return frozen({ kind: 'document', document: { components: [{ type: 'section', id: `${collectionId}:section`, title: category[1], subtitle: null, icon: 'manga', children: [{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation }] }] } }); }
export async function getDetail(request) { const id = contentId(request.id), url = bookUrl(id), $ = load(await fetchText(url)), title = clean($('.comic-title').attr('data-original-title') ?? $('.comic-title,#page-title').first().text()), cover = $('.comic-cover').attr('data-original-cover') ?? $('.comic-cover').attr('src') ?? '', author = clean($('#author-container').first().text()).replace(/^作者[:：]?/u, ''), description = clean($('.comic-desc').first().text()) || clean($('meta[name="description"]').attr('content') ?? ''), tags = $('#tagsContainer .tag,.comic-tags .tag').toArray().map(node => clean($(node).text())).filter(Boolean), latest = clean($('#newch').first().text()), item = summary(id, title || id, author, cover, description, tags); return frozen({ ...item, latestChapter: latest === '' ? item.latestChapter : { id: null, title: latest, url: null, updatedAt: null }, aliases: [], catalogUrl: url }); }
export async function getChapters(request) { const id = contentId(request.id), $ = load(await fetchText(bookUrl(id))), items = []; for (const node of $('#chapter-grid-container a.chapter-item,a.chapter-item[href*="/comic/"]').toArray()) {
    const href = $(node).attr('href') ?? '', match = /\/comic\/\d+\/(\d+)(?:_(\d+))?/u.exec(href), native = match?.[1], page = match?.[2] ?? '1', title = clean($(node).attr('data-title') ?? $(node).find('.chapter-name').text() ?? $(node).text());
    if (native === undefined || title === '')
        continue;
    items.push(frozen({ id: chapterId(id, native, page), title, order: items.length, url: null, volumeTitle: '章节', wordCount: null, updatedAt: null, isLocked: null, attributes: [] }));
} return frozen({ items, groups: items.length === 0 ? [] : [frozen({ id: `group:manga:${id}`, title: '章节', order: 0, episodes: items })] }); }
export async function getContent(request) { const book = contentId(request.id), { cid, page } = chapterNative(request.chapterId, book), json = await fetchJson(`${base}/api/comic/image/${encodeURIComponent(cid)}?page=${encodeURIComponent(page)}&page_size=60&image_source=`), rawImages = object(json.data).images, images = Array.isArray(rawImages) ? rawImages : [], pages = []; for (const value of images) {
    const upstream = typeof value === 'string' ? value : isObject(value) ? text(first(value.url, value.src)) : '';
    if (!safeUrl(upstream))
        continue;
    const index = pages.length;
    pages.push(frozen({ id: `page:${cid}:${page}:${index + 1}`, index, url: requireContext().resource.proxy({ kind: 'image', url: upstream, headers: { Referer: bookUrl(book) } }), mimeType: imageMime(upstream), width: null, height: null }));
} if (pages.length === 0)
    throw new Error('Chapter images are unavailable.'); return frozen({ chapterId: request.chapterId, contentKind: 'manga', title: null, updatedAt: null, text: null, pages: Object.freeze(pages) }); }
async function fetchJson(url) { const response = await requireContext().http.fetch(url, { headers }); if (!response.ok)
    throw new Error('Source request failed.'); const value = await response.json(); if (!isObject(value))
    throw new Error('Source response is invalid.'); return value; }
async function fetchText(url) { const response = await requireContext().http.fetch(url, { headers }); if (!response.ok)
    throw new Error('Source request failed.'); return response.text(); }
function apiSummary(value) { const id = bookId(first(value.id, value.comicId, value.url)); if (id === null)
    return null; return summary(id, text(first(value.title, value.name)) || id, text(first(value.author, value.authors)), text(first(value.cover, value.pic, value.coverUrl)), text(first(value.description, value.intro)), stringList(value.tags)); }
function summary(id, title, author, cover, description, tags) { return frozen({ id: `manga:${id}`, title, contentKind: 'manga', coverOrientation: 'portrait', author: author || null, url: bookUrl(id), coverUrl: proxyImage(cover), description: description || null, language: 'zh-CN', status: 'ongoing', access: 'unknown', wordCount: null, chapterCount: null, publishedAt: null, updatedAt: null, latestChapter: null, categories: tags, tags, attributes: [] }); }
function bookId(value) { const raw = text(value), match = /\/comic\/(\d+)/u.exec(raw); const id = match?.[1] ?? raw; return /^\d+$/u.test(id) ? id : null; }
function bookUrl(id) { return `${base}/comic/${id}`; }
function contentId(id) { const value = /^manga:(\d+)$/u.exec(id)?.[1]; if (value === undefined)
    throw new Error('Content ID is invalid.'); return value; }
function chapterId(book, cid, page) { return `manga:${book}:chapter:${Buffer.from(`${cid}|${page}`, 'utf8').toString('base64url')}`; }
function chapterNative(id, book) { const encoded = new RegExp(`^manga:${book}:chapter:([A-Za-z0-9_-]+)$`, 'u').exec(id)?.[1]; if (encoded === undefined)
    throw new Error('Chapter ID is invalid.'); const [cid, page] = Buffer.from(encoded, 'base64url').toString('utf8').split('|'); if (!cid || !page || !/^\d+$/u.test(cid) || !/^\d+$/u.test(page))
    throw new Error('Chapter ID is invalid.'); return { cid, page }; }
function proxyImage(value) { let url; try {
    url = new URL(value, base).toString();
}
catch {
    return null;
} return requireContext().resource.proxy({ kind: 'image', url, headers: { Referer: `${base}/` } }); }
function imageMime(url) { const path = new URL(url).pathname.toLowerCase(); return path.endsWith('.png') ? 'image/png' : path.endsWith('.webp') ? 'image/webp' : 'image/jpeg'; }
function safeUrl(value) { try {
    const url = new URL(value);
    return (url.protocol === 'https:' || url.protocol === 'http:') && url.username === '' && url.password === '';
}
catch {
    return false;
} }
function cursorPage(cursor, target) { if (cursor === null)
    return 1; const raw = cursor.startsWith(`${target}:`) ? cursor.slice(target.length + 1) : '', page = Number(raw); if (!Number.isSafeInteger(page) || page < 2 || page > 1000)
    throw new Error('Cursor is invalid.'); return page; }
function stringList(value) { if (Array.isArray(value))
    return value.map(text).filter(Boolean).slice(0, 32); const raw = text(value); return raw === '' ? [] : raw.split(/[,，/]/u).map(part => part.trim()).filter(Boolean).slice(0, 32); }
function clean(value) { return value.replace(/[\s\u00a0]+/gu, ' ').trim(); }
function nonNegative(value) { const n = Number(value); return Number.isSafeInteger(n) && n >= 0 ? n : null; }
function first(...values) { return values.find(value => value !== null && value !== undefined && value !== '') ?? ''; }
function records(value) { return Array.isArray(value) ? value.filter(isObject) : []; }
function object(value) { return isObject(value) ? value : {}; }
function isObject(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function text(value) { return typeof value === 'string' ? value.trim() : typeof value === 'number' ? String(value) : ''; }
function notNull(value) { return value !== null; }
function clamp(value) { return Math.max(1, Math.min(50, Math.floor(value))); }
function frozen(value) { return Object.freeze(value); }
function requireContext() { if (context === undefined)
    throw new Error('Source is not activated.'); return context; }
