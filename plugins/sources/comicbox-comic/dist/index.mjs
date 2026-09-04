/**
 * ComicBox 污污漫画原生数据源。
 *
 * 职责：解析 ComicBox 搜索、分类、详情和目录，并用公开 ctx.webview 获取动态章节图片。
 * 生命周期：activate 只保存 Runtime 上下文；每次章节读取创建并关闭独立隐藏 WebView。
 * IO：静态页面走 ctx.http，动态章节走 ctx.webview；所有图片经 ctx.resource.proxy。
 * 稳定标识：作品与章节使用站内路径的 base64url 编码，不包含域名或会话状态。
 */
import { load } from 'cheerio';
const base = 'https://www.comicbox.xyz', headers = { 'User-Agent': 'Mozilla/5.0 MgRead' }, channels = ['热门', '全部', 'Fate', '东方', '原神', '汉化', '日漫', '韩漫', '单行本', '长篇', '短篇'];
let context;
export async function activate(next) { context = next; next.log.info('source_activated'); }
export async function search(request) { if (request.cursor !== null)
    throw new Error('Cursor is invalid.'); const query = request.query.trim(); if (!query)
    return frozen({ items: [], nextCursor: null, totalCount: 0 }); const values = parseCards(await text(`${base}/search?keyword=${encodeURIComponent(query)}`), '.sp-search-card'), items = values.map(summary).slice(0, clamp(request.pageSize)); return frozen({ items, nextCursor: null, totalCount: items.length }); }
export async function searchSuggestions(_request) { return frozen({ items: [], nextCursor: null }); }
export async function discover(request) { if (request.target === null)
    return frozen({ kind: 'document', document: { components: [{ type: 'section', id: 'comicbox-channels', title: '污污漫画', subtitle: 'ComicBox 分类', icon: 'manga', children: [{ type: 'categoryCollection', id: 'comicbox-channel-list', layout: 'chips', categories: channels.map((title, index) => ({ id: String(index), title, target: `channel:${index}`, count: null, url: null, icon: 'manga' })) }] }] } }); const index = Number(request.target.replace(/^channel:/u, '')), title = channels[index]; if (!Number.isSafeInteger(index) || title === undefined)
    throw new Error('Discovery target is invalid.'); const page = cursorPage(request.cursor, request.target), size = clamp(request.pageSize), url = title === '热门' ? `${base}/index` : `${base}/booklist?tag=${encodeURIComponent(title)}&area=-1&end=-1&page=${page}`, values = parseCards(await text(url), title === '热门' ? '.sp-bcarousel-item, .sp-booklist-card' : '.sp-booklist-card'), contents = values.map(summary).slice(0, size), collectionId = `comicbox:${index}`, items = contents.map(content => frozen({ content, rank: null, metric: null, recommendation: null })), continuation = values.length >= size ? frozen({ target: request.target, cursor: `channel:${index}:${page + 1}` }) : null; if (request.collectionId !== null) {
    if (request.collectionId !== collectionId)
        throw new Error('Discovery collection is invalid.');
    return frozen({ kind: 'append', collectionId, items, continuation });
} return frozen({ kind: 'document', document: { components: [{ type: 'section', id: `${collectionId}:section`, title, subtitle: null, icon: 'manga', children: [{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation }] }] } }); }
export async function getDetail(request) { const path = contentPath(request.id), $ = load(await text(new URL(path, base).toString())), title = clean($('meta[property="og:title"]').attr('content') ?? $('h1.sp-book-title,h1').first().text()), cover = $('meta[property="og:image"]').attr('content') ?? '', description = clean($('meta[property="og:description"]').attr('content') ?? $('.sp-book-summary').first().text()), tags = $('.sp-book-tag').toArray().map(node => clean($(node).text())).filter(Boolean), chapters = chapterNodes($, path), item = summary({ path, title: title || path, cover, description }); return frozen({ ...item, categories: tags, tags, chapterCount: chapters.length, latestChapter: chapters.length ? { id: chapterId(path, chapters.at(-1)?.path ?? ''), title: chapters.at(-1)?.title ?? '', url: null, updatedAt: null } : null, aliases: [], catalogUrl: new URL(path, base).toString() }); }
export async function getChapters(request) { const path = contentPath(request.id), $ = load(await text(new URL(path, base).toString())), chapters = chapterNodes($, path), items = chapters.map((chapter, index) => frozen({ id: chapterId(path, chapter.path), title: chapter.title, order: index, url: null, volumeTitle: null, wordCount: null, updatedAt: null, isLocked: false, attributes: [] })); return frozen({ items, groups: [] }); }
export async function getContent(request) { const book = contentPath(request.id), path = chapterPath(request.chapterId, book), url = new URL(path, base).toString(), page = await requireContext().webview.open({ visible: false, timeoutMs: 30000 }); let raw; try {
    await page.navigate(url, { timeoutMs: 30000 });
    raw = await page.executeJavaScript(`Array.from(document.querySelectorAll('img')).map(i=>i.currentSrc||i.src||i.dataset.src||i.dataset.original||'').filter(u=>u&&!u.includes('/static/'))`, { timeoutMs: 30000 });
}
finally {
    await page.close();
} const values = Array.isArray(raw) ? raw : [], pages = []; for (const value of values) {
    const upstream = typeof value === 'string' ? value : '';
    if (!safeUrl(upstream))
        continue;
    const pageIndex = pages.length;
    pages.push(frozen({ id: `page:${encode(path)}:${pageIndex + 1}`, index: pageIndex, url: requireContext().resource.proxy({ kind: 'image', url: upstream, headers: { Referer: url } }), mimeType: imageMime(upstream), width: null, height: null }));
} if (!pages.length)
    throw new Error('Chapter images are unavailable.'); return frozen({ chapterId: request.chapterId, contentKind: 'manga', title: null, updatedAt: null, text: null, pages: Object.freeze(pages) }); }
async function text(url) { const response = await requireContext().http.fetch(url, { headers }); if (!response.ok)
    throw new Error('Source request failed.'); return response.text(); }
function parseCards(source, selector) { const $ = load(source), result = new Map(); for (const node of $(selector).toArray()) {
    const card = $(node), href = card.attr('href') ?? card.find('a[href*="/book/"]').first().attr('href') ?? '';
    if (!href.includes('/book/'))
        continue;
    const path = new URL(href, base).pathname, title = clean(card.attr('title') ?? card.find('.sp-search-card-title,.sp-booklist-title,.sp-bcarousel-label').first().text());
    if (!title)
        continue;
    const image = card.find('img,.cropped').first(), cover = image.attr('data-src') ?? image.attr('src') ?? '', description = clean(card.find('.sp-search-card-desc,.sp-booklist-desc').first().text());
    result.set(path, { path, title, cover, description });
} return [...result.values()]; }
function chapterNodes($, _book) { const result = new Map(); for (const node of $('.sp-chapter-grid a.sp-chapter-item,a.sp-chapter-item').toArray()) {
    const link = $(node), href = link.attr('href') ?? '', title = clean(link.attr('title') ?? link.text());
    if (!href || !title)
        continue;
    const path = new URL(href, base).pathname;
    result.set(path, { path, title });
} return [...result.values()]; }
function summary(value) { return frozen({ id: `manga:${encode(value.path)}`, title: value.title, contentKind: 'manga', coverOrientation: 'portrait', author: null, url: new URL(value.path, base).toString(), coverUrl: proxyImage(value.cover), description: value.description || null, language: 'zh-CN', status: 'unknown', access: 'unknown', wordCount: null, chapterCount: null, publishedAt: null, updatedAt: null, latestChapter: null, categories: [], tags: [], attributes: [] }); }
function contentPath(id) { const value = /^manga:([A-Za-z0-9_-]+)$/u.exec(id)?.[1], path = value ? decode(value) : ''; if (!path.startsWith('/book/'))
    throw new Error('Content ID is invalid.'); return path; }
function chapterId(book, path) { return `manga:${encode(book)}:chapter:${encode(path)}`; }
function chapterPath(id, book) { const value = new RegExp(`^manga:${encode(book)}:chapter:([A-Za-z0-9_-]+)$`, 'u').exec(id)?.[1], path = value ? decode(value) : ''; if (!path.startsWith('/'))
    throw new Error('Chapter ID is invalid.'); return path; }
function encode(value) { return Buffer.from(value).toString('base64url'); }
function decode(value) { return Buffer.from(value, 'base64url').toString('utf8'); }
function proxyImage(value) { let url; try {
    url = new URL(value, base).toString();
}
catch {
    return null;
} return requireContext().resource.proxy({ kind: 'image', url, headers: { Referer: `${base}/` } }); }
function safeUrl(value) { try {
    return ['http:', 'https:'].includes(new URL(value).protocol);
}
catch {
    return false;
} }
function imageMime(url) { const path = new URL(url).pathname.toLowerCase(); return path.endsWith('.png') ? 'image/png' : path.endsWith('.webp') ? 'image/webp' : 'image/jpeg'; }
function cursorPage(cursor, target) { if (cursor === null)
    return 1; const page = Number(cursor.startsWith(`${target}:`) ? cursor.slice(target.length + 1) : ''); if (!Number.isSafeInteger(page) || page < 2)
    throw new Error('Cursor is invalid.'); return page; }
function clean(value) { return value.replaceAll(/\s+/gu, ' ').trim(); }
function clamp(value) { return Math.max(1, Math.min(50, Math.floor(value))); }
function frozen(value) { return Object.freeze(value); }
function requireContext() { if (!context)
    throw new Error('Source is not activated.'); return context; }
