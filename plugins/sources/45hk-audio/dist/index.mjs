/**
 * 酷听音乐原生数据源。
 *
 * 职责：直接解析 45hk 榜单、检索、歌曲页，并提交站点自带的 CSRF 人机确认。
 * 生命周期：activate 注入 Runtime；仅在当前插件进程内保存站点响应 Cookie。
 * IO：页面与播放 POST 走 ctx.http，封面和音频经 ctx.resource.proxy。
 * 稳定标识：使用 /mp3/{slug}.html 中的站点歌曲 slug。
 */
import { load } from 'cheerio';
const base = 'https://www.45hk.com', ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/92.0.4515.131 Safari/537.36', categories = Object.freeze([['top', '榜单', '/list/top.html'], ['all', '全部歌单', '/playtype/index/{page}.html'], ['dj', 'DJ', '/playtype/dj/{page}.html'], ['douyin', '抖音', '/playtype/douyin/{page}.html'], ['classic', '经典', '/playtype/jingdian/{page}.html'], ['bgm', 'BGM', '/playtype/bgm/{page}.html'], ['ancient', '古风', '/playtype/gufeng/{page}.html']]);
let context, cookie = '';
export async function activate(next) { context = next; cookie = ''; next.log.info('source_activated'); }
export async function search(request) { const query = request.query.trim(); if (query === '')
    return frozen({ items: [], nextCursor: null, totalCount: 0 }); const page = cursorPage(request.cursor, 'search'), limit = clamp(request.pageSize), values = parseSongs(await getPage(`${base}/so/${encodeURIComponent(query)}/${page}.html`)).slice(0, limit); return frozen({ items: values, nextCursor: values.length >= limit ? `search:${page + 1}` : null, totalCount: null }); }
export async function searchSuggestions(_request) { return frozen({ items: [], nextCursor: null }); }
export async function discover(request) { if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null)
        throw new Error('Initial discovery request is invalid.');
    return frozen({ kind: 'document', document: { components: [{ type: 'section', id: 'audio-categories', title: '音乐分类', subtitle: '按榜单与歌单浏览', icon: 'audio', children: [{ type: 'categoryCollection', id: 'audio-categories-list', layout: 'chips', categories: categories.map(([id, title]) => ({ id, title, target: `category:${id}`, count: null, url: null, icon: 'audio' })) }] }] } });
} const category = categories.find(([id]) => request.target === `category:${id}`); if (category === undefined)
    throw new Error('Discovery target is invalid.'); const page = cursorPage(request.cursor, request.target), limit = clamp(request.pageSize), [id, title, path] = category, url = `${base}${path.replace('{page}', String(page))}`, values = parseSongs(await getPage(url)).slice(0, limit), collectionId = `audio:${id}`, items = values.map(content => frozen({ content, rank: null, metric: null, recommendation: null })), continuation = values.length >= limit ? frozen({ target: request.target, cursor: `${request.target}:${page + 1}` }) : null; if (request.collectionId !== null) {
    if (request.collectionId !== collectionId)
        throw new Error('Discovery collection is invalid.');
    return frozen({ kind: 'append', collectionId, items, continuation });
} return frozen({ kind: 'document', document: { components: [{ type: 'section', id: `${collectionId}:section`, title, subtitle: null, icon: 'audio', children: [{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation }] }] } }); }
export async function getDetail(request) { const slug = contentId(request.id), url = songUrl(slug), $ = load(await getPage(url)), rawTitle = clean($('div.list_r > h1,h1,title').first().text()).replace(/\s*[-–—|]\s*酷听音乐.*$/u, ''), parsed = parseTitle(rawTitle), cover = $('div.pic img,img').first().attr('src') ?? '', author = parsed.author || clean($('.play_singer .name a').first().text()), description = clean($('div.content,div.list_r').first().text()), item = summary(slug, parsed.name || rawTitle, author, cover); return frozen({ ...item, description: description || null, aliases: [], catalogUrl: url }); }
export async function getChapters(request) { const slug = contentId(request.id), $ = load(await getPage(songUrl(slug))), title = clean($('div.list_r > h1,h1,title').first().text()).replace(/\s*[-–—|]\s*酷听音乐.*$/u, '') || '播放', chapter = frozen({ id: `audio:${encodeKey(slug)}:main`, title, order: 0, url: songUrl(slug), volumeTitle: '单曲', wordCount: null, updatedAt: null, isLocked: null, attributes: [] }); return frozen({ items: [chapter], groups: [frozen({ id: `group:${encodeKey(slug)}:single`, title: '单曲', order: 0, episodes: [chapter] })] }); }
export async function getContent(request) { const slug = contentId(request.id); if (request.chapterId !== `audio:${encodeKey(slug)}:main`)
    throw new Error('Chapter ID is invalid.'); const page = songUrl(slug); await getPage(page); const body = new URLSearchParams({ id: slug, type: 'music' }), response = await httpRequest(`${base}/js/play.php`, { method: 'POST', headers: requestHeaders(page, 'application/x-www-form-urlencoded; charset=UTF-8'), body: body.toString() }), value = await response.json(); if (!isObject(value))
    throw new Error('Playback response is invalid.'); const upstream = text(value.url); if (!safeUrl(upstream))
    throw new Error('Audio address is unavailable.'); const mediaHeaders = { Referer: page, 'User-Agent': ua }; return frozen({ chapterId: request.chapterId, contentKind: 'audio', title: null, updatedAt: null, text: null, pages: [], media: { url: requireContext().resource.proxy({ kind: 'audio', url: upstream, headers: mediaHeaders }), resourceType: 'audio', resourcePolicy: 'sessionOnly', expiresAt: null, mimeType: mime(upstream), headers: mediaHeaders } }); }
async function getPage(url) { let response = await httpRequest(url, { headers: requestHeaders(`${base}/`) }), html = await response.text(); if (isVerify(html)) {
    const token = /name=["']csrf_token["'][^>]*value=["']([^"']+)/iu.exec(html)?.[1];
    if (!token)
        throw new Error('Verification token is unavailable.');
    const body = new URLSearchParams({ csrf_token: token, human_check: 'on' });
    response = await httpRequest(url, { method: 'POST', headers: requestHeaders(url, 'application/x-www-form-urlencoded'), body: body.toString() });
    html = await response.text();
    if (isVerify(html)) {
        response = await httpRequest(url, { headers: requestHeaders(`${base}/`) });
        html = await response.text();
    }
} if (isVerify(html))
    throw new Error('Source verification was not accepted.'); return html; }
async function httpRequest(url, init) { const response = await requireContext().http.fetch(url, init); updateCookie(response.headers); if (!response.ok)
    throw new Error('Source request failed.'); return response; }
function requestHeaders(referer, contentType) { return { Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8', ...(contentType ? { 'Content-Type': contentType } : {}), ...(cookie ? { Cookie: cookie } : {}), Referer: referer, 'User-Agent': ua, 'X-Requested-With': contentType?.includes('charset') ? 'XMLHttpRequest' : '' }; }
function updateCookie(value) { const raw = value.get('set-cookie'); if (raw)
    cookie = raw.split(';')[0] ?? cookie; }
function parseSongs(html) { const $ = load(html), values = new Map(); $('a[href^="/mp3/"]').each((_, node) => { const href = $(node).attr('href') ?? '', slug = /\/mp3\/([^/.]+)\.html/u.exec(href)?.[1]; if (!slug || values.has(slug))
    return; const parsed = parseTitle($(node).attr('title') ?? $(node).text()); if (parsed.name !== '')
    values.set(slug, summary(slug, parsed.name, parsed.author, '')); }); return [...values.values()]; }
function parseTitle(value) { const title = clean(value), match = /^(.+?)《(.+?)》/u.exec(title); return match ? { name: clean(match[2] ?? ''), author: clean(match[1] ?? '') } : { name: title, author: '' }; }
function summary(slug, title, author, cover) { const id = encodeKey(slug); return frozen({ id: `audio:${id}`, title, contentKind: 'audio', coverOrientation: 'portrait', author: author || null, url: songUrl(slug), coverUrl: proxyImage(cover), description: null, language: 'zh-CN', status: 'completed', access: 'free', wordCount: null, chapterCount: 1, publishedAt: null, updatedAt: null, latestChapter: { id: `audio:${id}:main`, title: '播放', url: null, updatedAt: null }, categories: ['音乐'], tags: [], attributes: [] }); }
function songUrl(slug) { return `${base}/mp3/${encodeURIComponent(slug)}.html`; }
function contentId(id) { const value = /^audio:([^:]+)$/u.exec(id)?.[1]; if (value === undefined)
    throw new Error('Content ID is invalid.'); return decodeKey(value); }
function proxyImage(value) { if (value === '')
    return null; let url; try {
    url = new URL(value, base).toString();
}
catch {
    return null;
} return requireContext().resource.proxy({ kind: 'image', url, headers: { Referer: `${base}/` } }); }
function isVerify(value) { return value.includes('安全人机验证') && value.includes('csrf_token'); }
function safeUrl(value) { try {
    const url = new URL(value);
    return (url.protocol === 'https:' || url.protocol === 'http:') && url.username === '' && url.password === '';
}
catch {
    return false;
} }
function mime(url) { return /\.m4a(?:$|[?#])/iu.test(url) ? 'audio/mp4' : /\.aac(?:$|[?#])/iu.test(url) ? 'audio/aac' : 'audio/mpeg'; }
function encodeKey(value) { return Buffer.from(value, 'utf8').toString('base64url'); }
function decodeKey(value) { if (!/^[A-Za-z0-9_-]+$/u.test(value))
    throw new Error('Source key is invalid.'); return Buffer.from(value, 'base64url').toString('utf8'); }
function clean(value) { return value.replace(/[\s\u00a0]+/gu, ' ').trim(); }
function cursorPage(cursor, target) { if (cursor === null)
    return 1; const raw = cursor.startsWith(`${target}:`) ? cursor.slice(target.length + 1) : '', page = Number(raw); if (!Number.isSafeInteger(page) || page < 2 || page > 1000)
    throw new Error('Cursor is invalid.'); return page; }
function clamp(value) { return Math.max(1, Math.min(50, Math.floor(value))); }
function isObject(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function text(value) { return typeof value === 'string' ? value.trim() : ''; }
function frozen(value) { return Object.freeze(value); }
function requireContext() { if (context === undefined)
    throw new Error('Source is not activated.'); return context; }
