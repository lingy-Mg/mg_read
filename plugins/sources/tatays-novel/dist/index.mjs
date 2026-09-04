/**
 * 126小说网原生数据源。
 *
 * 职责：直接解析 tatays.com 的分类、POST 检索、详情、分页目录和正文。
 * 生命周期：activate 注入 Runtime 上下文；插件不持有登录态或旧规则对象。
 * IO：HTML 只经 ctx.http 获取，封面登记到 ctx.resource.proxy。
 * 稳定标识：作品和章节均使用站点 URL 中的数字 ID。
 */
import { load } from 'cheerio';
const base = 'https://www.tatays.com', headers = Object.freeze({ Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8', 'Accept-Language': 'zh-CN,zh;q=0.9', Referer: `${base}/`, 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' }), categories = Object.freeze([['xuanhuan', '玄幻奇幻'], ['wuxia', '武侠修真'], ['yanqing', '都市言情'], ['lishi', '历史军事'], ['kehuan', '科幻小说'], ['wangyou', '网游小说'], ['nvsheng', '女生小说'], ['qita', '其他小说']]);
let context;
export async function activate(next) { context = next; next.log.info('source_activated'); }
export async function search(request) { const query = request.query.trim(); if (query === '')
    return frozen({ items: [], nextCursor: null, totalCount: 0 }); const page = cursorPage(request.cursor, 'search'), limit = clamp(request.pageSize), body = new URLSearchParams({ searchtype: 'all', searchkey: query, page: String(page) }), html = await fetchText(`${base}/modules/article/search.php`, { method: 'POST', headers: { ...headers, 'Content-Type': 'application/x-www-form-urlencoded' }, body: body.toString() }), values = parseSearch(html).slice(0, limit); return frozen({ items: values, nextCursor: values.length >= limit ? `search:${page + 1}` : null, totalCount: null }); }
export async function searchSuggestions(_request) { return frozen({ items: [], nextCursor: null }); }
export async function discover(request) { if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null)
        throw new Error('Initial discovery request is invalid.');
    return frozen({ kind: 'document', document: { components: [{ type: 'section', id: 'novel-categories', title: '小说分类', subtitle: '按题材浏览', icon: 'book', children: [{ type: 'categoryCollection', id: 'novel-categories-list', layout: 'chips', categories: categories.map(([id, title]) => ({ id, title, target: `category:${id}`, count: null, url: null, icon: 'book' })) }] }] } });
} const category = categories.find(([id]) => request.target === `category:${id}`); if (category === undefined)
    throw new Error('Discovery target is invalid.'); const page = cursorPage(request.cursor, request.target), limit = clamp(request.pageSize), [id, title] = category, values = parseListing(await fetchText(`${base}/${id}/p${page}.html`)).slice(0, limit), collectionId = `novel:${id}`, items = values.map(content => frozen({ content, rank: null, metric: null, recommendation: null })), continuation = values.length >= limit ? frozen({ target: request.target, cursor: `${request.target}:${page + 1}` }) : null; if (request.collectionId !== null) {
    if (request.collectionId !== collectionId)
        throw new Error('Discovery collection is invalid.');
    return frozen({ kind: 'append', collectionId, items, continuation });
} return frozen({ kind: 'document', document: { components: [{ type: 'section', id: `${collectionId}:section`, title, subtitle: null, icon: 'book', children: [{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation }] }] } }); }
export async function getDetail(request) { const id = contentId(request.id), url = bookUrl(id), $ = load(await fetchText(url)), title = clean($('.chapter-list-info .mid h2').first().text()) || clean($('meta[property="og:title"]').attr('content') ?? '') || `小说 ${id}`, cover = $('.chapter-img img').first().attr('src') ?? $('meta[property="og:image"]').attr('content') ?? '', intro = clean($('.info .intro').first().text()), latest = clean($('.lastchapter a').first().text()), details = $('.mid .clearfix dd').toArray().map(node => clean($(node).text())), author = details.map(value => /作者[：:]\s*([^|]+)/u.exec(value)?.[1]?.trim() ?? '').find(Boolean) ?? '', category = details.map(value => /类型[：:]\s*(.+)$/u.exec(value)?.[1]?.trim() ?? '').find(Boolean) ?? '', item = summary(id, title, author, cover, category, latest); return frozen({ ...item, description: intro || null, aliases: [], catalogUrl: url }); }
export async function getChapters(request) { const id = contentId(request.id), root = bookUrl(id), firstHtml = await fetchText(root), maxPage = Math.min(100, chapterPageCount(firstHtml, id)), pages = await Promise.all(Array.from({ length: Math.max(0, maxPage - 1) }, (_, index) => fetchText(`${root}${index + 2}s.html`))), chapters = parseChapters([firstHtml, ...pages], id); if (chapters.length === 0)
    throw new Error('No chapters found.'); const group = frozen({ id: `group:${id}:default`, title: '正文', order: 0, episodes: chapters }); return frozen({ items: chapters, groups: [group] }); }
export async function getContent(request) { const id = contentId(request.id), chapter = parseChapterId(request.chapterId, id), $ = load(await fetchText(chapterUrl(id, chapter))), html = $('.chapter-content').first().html() ?? '', paragraphs = decode(html.replace(/<br\s*\/?\s*>/giu, '\n').replace(/<\/?p[^>]*>/giu, '\n').replace(/<[^>]+>/gu, ' ')).split(/\n+/u).map(clean).filter(value => value !== '' && !/本章未完|加入书签|章节报错|126小说|tatays/iu.test(value)); if (paragraphs.length === 0)
    throw new Error('Chapter content is empty.'); return frozen({ chapterId: request.chapterId, contentKind: 'novel', title: null, updatedAt: null, text: paragraphs.join('\n\n'), pages: [], media: null }); }
async function fetchText(url, init = { headers }) { const response = await requireContext().http.fetch(url, init); if (!response.ok)
    throw new Error('Source request failed.'); return response.text(); }
function parseSearch(html) { const $ = load(html), result = []; $('.sort-list.search_words li').slice(1).each((_, node) => { const href = $(node).find('.one a').first().attr('href') ?? '', id = bookId(href); if (id === null)
    return; const title = clean($(node).find('.one a').first().text()), author = clean($(node).find('.three').first().text()), latest = clean($(node).find('.two a').first().text()); if (title !== '')
    result.push(summary(id, title, author, '', '', latest)); }); return result; }
function parseListing(html) { const $ = load(html), result = []; $('.list-title li').each((_, node) => { const href = $(node).find('a').first().attr('href') ?? '', id = bookId(href); if (id === null)
    return; const title = clean($(node).find('h2').first().text()), cover = $(node).find('img').first().attr('src') ?? '', author = /作者[：:]\s*([^|]+)/u.exec(clean($(node).find('p.info').first().text()))?.[1]?.trim() ?? ''; if (title !== '')
    result.push(summary(id, title, author, cover, '', '')); }); return result; }
function parseChapters(htmlPages, book) { const seen = new Set(), values = []; for (const html of htmlPages) {
    const $ = load(html);
    $('.chapter-box .chapter-list.clears a').each((_, node) => { const href = $(node).attr('href') ?? '', match = new RegExp(`/book/${book}/(\\d+)\\.html`, 'u').exec(href), title = clean($(node).text()); if (!match?.[1] || title === '' || seen.has(match[1]))
        return; seen.add(match[1]); values.push({ id: match[1], title }); });
} values.sort((a, b) => Number(a.id) - Number(b.id)); return values.slice(0, 5000).map((value, index) => frozen({ id: `novel:${book}:${value.id}`, title: value.title, order: index, url: chapterUrl(book, value.id), volumeTitle: '正文', wordCount: null, updatedAt: null, isLocked: null, attributes: [] })); }
function summary(id, title, author, cover, category, latest) { return frozen({ id: `novel:${id}`, title: decode(title), contentKind: 'novel', coverOrientation: 'portrait', author: author || null, url: bookUrl(id), coverUrl: proxyImage(cover), description: null, language: 'zh-CN', status: 'unknown', access: 'free', wordCount: null, chapterCount: null, publishedAt: null, updatedAt: null, latestChapter: latest === '' ? null : { id: null, title: latest, url: null, updatedAt: null }, categories: category === '' ? [] : [category], tags: [], attributes: [] }); }
function chapterPageCount(html, id) { let max = 1; for (const match of html.matchAll(new RegExp(`/book/${id}/(\\d+)s\\.html`, 'gu'))) {
    const value = Number(match[1]);
    if (Number.isSafeInteger(value) && value > max)
        max = value;
} const fraction = /<kbd>[\s\S]*?(\d+)\s*\/\s*(\d+)[\s\S]*?<\/kbd>/iu.exec(html), value = Number(fraction?.[2]); return Number.isSafeInteger(value) && value > max ? value : max; }
function bookId(url) { return /\/book\/(\d+)/u.exec(url)?.[1] ?? null; }
function bookUrl(id) { return `${base}/book/${id}/`; }
function chapterUrl(book, chapter) { return `${base}/book/${book}/${chapter}.html`; }
function contentId(id) { const value = /^novel:(\d+)$/u.exec(id)?.[1]; if (value === undefined)
    throw new Error('Content ID is invalid.'); return value; }
function parseChapterId(id, book) { const value = new RegExp(`^novel:${book}:(\\d+)$`, 'u').exec(id)?.[1]; if (value === undefined)
    throw new Error('Chapter ID is invalid.'); return value; }
function proxyImage(value) { const raw = value.trim(); if (raw === '')
    return null; let url; try {
    url = new URL(raw, base).toString();
}
catch {
    return null;
} return requireContext().resource.proxy({ kind: 'image', url, headers: { Referer: `${base}/` } }); }
function decode(value) { return value.replace(/&nbsp;/giu, ' ').replace(/&amp;/giu, '&').replace(/&quot;/giu, '"').replace(/&#39;/giu, "'").replace(/&lt;/giu, '<').replace(/&gt;/giu, '>'); }
function clean(value) { return decode(value).replace(/[\s\u3000\u00a0]+/gu, ' ').trim(); }
function cursorPage(cursor, target) { if (cursor === null)
    return 1; const raw = cursor.startsWith(`${target}:`) ? cursor.slice(target.length + 1) : '', page = Number(raw); if (!Number.isSafeInteger(page) || page < 2 || page > 1000)
    throw new Error('Cursor is invalid.'); return page; }
function clamp(value) { return Math.max(1, Math.min(50, Math.floor(value))); }
function frozen(value) { return Object.freeze(value); }
function requireContext() { if (context === undefined)
    throw new Error('Source is not activated.'); return context; }
