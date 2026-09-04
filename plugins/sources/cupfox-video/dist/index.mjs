const base = 'https://www.cupfox.in', headers = Object.freeze({ Accept: 'text/html,application/xhtml+xml,*/*', 'User-Agent': 'Mozilla/5.0 MgRead', Referer: `${base}/` }), categories = Object.freeze([['tv', '剧集'], ['movie', '电影'], ['anime', '动漫'], ['show', '综艺']]);
let context;
export async function activate(next) { context = next; next.log.info('source_activated'); }
export async function search(request) { const query = request.query.trim(); if (query === '')
    return frozen({ items: [], nextCursor: null, totalCount: 0 }); const page = cursorPage(request.cursor, 'search'), limit = clamp(request.pageSize), url = `${base}/search?q=${encodeURIComponent(query)}${page > 1 ? `&page=${page}` : ''}`, values = parseList(await fetchText(url)).slice(0, limit); return frozen({ items: values, nextCursor: values.length >= limit ? `search:${page + 1}` : null, totalCount: null }); }
export async function searchSuggestions(_request) { return frozen({ items: [], nextCursor: null }); }
export async function discover(request) { if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null)
        throw new Error('Initial discovery request is invalid.');
    return frozen({ kind: 'document', document: { components: [{ type: 'section', id: 'cupfox-categories', title: '影视分类', subtitle: '按频道浏览', icon: 'video', children: [{ type: 'categoryCollection', id: 'cupfox-category-list', layout: 'chips', categories: categories.map(([id, title]) => ({ id, title, target: `category:${id}`, count: null, url: null, icon: 'video' })) }] }] } });
} const category = categories.find(([id]) => request.target === `category:${id}`); if (category === undefined)
    throw new Error('Discovery target is invalid.'); const page = cursorPage(request.cursor, request.target), limit = clamp(request.pageSize), url = `${base}/type/${category[0]}/${page > 1 ? `page/${page}/` : ''}`, values = parseList(await fetchText(url)).slice(0, limit), collectionId = `video:${category[0]}`, items = values.map(content => frozen({ content, rank: null, metric: null, recommendation: null })), continuation = values.length >= limit ? frozen({ target: request.target, cursor: `${request.target}:${page + 1}` }) : null; if (request.collectionId !== null) {
    if (request.collectionId !== collectionId)
        throw new Error('Discovery collection is invalid.');
    return frozen({ kind: 'append', collectionId, items, continuation });
} return frozen({ kind: 'document', document: { components: [{ type: 'section', id: `${collectionId}:section`, title: category[1], subtitle: null, icon: 'video', children: [{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation }] }] } }); }
export async function getDetail(request) { const id = contentId(request.id), url = detailUrl(id), html = await fetchText(url), title = strip(firstCapture(html, /<h1[^>]*>([\s\S]*?)<\/h1>/iu) || firstCapture(html, /<title[^>]*>([\s\S]*?)<\/title>/iu)).replace(/在线观看\s*-\s*茶杯狐.*$/u, '').trim() || `视频 ${id}`, cover = firstCapture(html, /<img[^>]*src=["']([^"']*\/(?:uimg|simg)\/[^"']+)["']/iu), description = strip(firstCapture(html, /<[^>]*class=["'][^"']*(?:subject-desc|desc)[^"']*["'][^>]*>([\s\S]*?)<\/[^>]+>/iu)).replace(/^简介[：:]?/u, ''), item = summary(id, title, cover); return frozen({ ...item, description: description || null, aliases: [], catalogUrl: url }); }
export async function getChapters(request) { const id = contentId(request.id), html = await fetchText(detailUrl(id)), items = []; for (const match of html.matchAll(/<([a-z][\w-]*)\b([^>]*\bep_slug=["']([^"']+)["'][^>]*)>([\s\S]*?)<\/\1>/giu)) {
    const slug = match[3] ?? '', title = strip(match[4] ?? '');
    if (slug === '' || title === '')
        continue;
    items.push(frozen({ id: `video:${id}:ep:${encodeKey(slug)}`, title, order: items.length, url: null, volumeTitle: '播放列表', wordCount: null, updatedAt: null, isLocked: null, attributes: [] }));
} return frozen({ items, groups: items.length === 0 ? [] : [frozen({ id: `group:video:${id}`, title: '播放列表', order: 0, episodes: items })] }); }
export async function getContent(request) { const id = contentId(request.id), slug = chapterSlug(request.chapterId, id), page = `${base}/tea/${id}${slug === '' ? '' : `-${encodeURIComponent(slug)}`}`, raw = await fetchText(page), encoded = firstCapture(raw, /"play_data"\s*:\s*"([^"]+)"/iu), candidate = encoded === '' ? firstCapture(raw, /(https:\/\/[^"'\s]+\.m3u8[^"'\s]*)/iu) : decodeUrl(encoded), upstream = candidate.replaceAll('\\/', '/'); if (!safeUrl(upstream))
    throw new Error('Playback address is unavailable.'); const resourceType = /\.m3u8(?:$|[?#])/iu.test(upstream) ? 'hls' : 'video', mediaHeaders = { Referer: detailUrl(id), 'User-Agent': headers['User-Agent'] }; return frozen({ chapterId: request.chapterId, contentKind: 'video', title: null, updatedAt: null, text: null, pages: [], media: { url: requireContext().resource.proxy({ kind: resourceType, url: upstream, headers: mediaHeaders }), resourceType, resourcePolicy: 'sessionOnly', expiresAt: null, mimeType: resourceType === 'hls' ? 'application/vnd.apple.mpegurl' : 'video/mp4', headers: mediaHeaders } }); }
async function fetchText(url) { const response = await requireContext().http.fetch(url, { headers }); if (!response.ok)
    throw new Error('Source request failed.'); return response.text(); }
function parseList(html) { const values = new Map(); for (const match of html.matchAll(/<a\b([^>]*)href=["']([^"']*\/vod-detail\/(\d+)\.html)["']([^>]*)>([\s\S]*?)<\/a>/giu)) {
    const id = match[3] ?? '', attrs = `${match[1] ?? ''} ${match[4] ?? ''}`, body = match[5] ?? '', title = strip(firstCapture(body, /<[^>]*class=["'][^"']*movie-title[^"']*["'][^>]*>([\s\S]*?)<\/[^>]+>/iu)) || attribute(attrs, 'title') || strip(body) || `视频 ${id}`, image = /<img\b[^>]*>/iu.exec(body)?.[0] ?? '', cover = attribute(image, 'src') || attribute(image, 'data-src');
    if (id !== '' && !values.has(id))
        values.set(id, summary(id, title, cover));
} return [...values.values()]; }
function summary(id, title, cover) { return frozen({ id: `video:${id}`, title, contentKind: 'video', coverOrientation: 'portrait', author: null, url: detailUrl(id), coverUrl: proxyImage(cover), description: null, language: 'zh-CN', status: 'unknown', access: 'unknown', wordCount: null, chapterCount: null, publishedAt: null, updatedAt: null, latestChapter: null, categories: [], tags: [], attributes: [] }); }
function detailUrl(id) { return `${base}/vod-detail/${id}.html`; }
function contentId(id) { const value = /^video:(\d+)$/u.exec(id)?.[1]; if (value === undefined)
    throw new Error('Content ID is invalid.'); return value; }
function chapterSlug(id, content) { const encoded = new RegExp(`^video:${content}:ep:([A-Za-z0-9_-]+)$`, 'u').exec(id)?.[1]; if (encoded === undefined)
    throw new Error('Chapter ID is invalid.'); return decodeKey(encoded); }
function encodeKey(value) { return Buffer.from(value, 'utf8').toString('base64url'); }
function decodeKey(value) { if (!/^[A-Za-z0-9_-]+$/u.test(value))
    throw new Error('Source key is invalid.'); return Buffer.from(value, 'base64url').toString('utf8'); }
function proxyImage(value) { if (value === '')
    return null; let url; try {
    url = new URL(value, base).toString();
}
catch {
    return null;
} return requireContext().resource.proxy({ kind: 'image', url, headers: { Referer: `${base}/` } }); }
function decodeUrl(value) { try {
    return decodeURIComponent(value);
}
catch {
    return value;
} }
function safeUrl(value) { try {
    const url = new URL(value);
    return (url.protocol === 'https:' || url.protocol === 'http:') && url.username === '' && url.password === '';
}
catch {
    return false;
} }
function attribute(value, name) { return new RegExp(`${name}=["']([^"']+)["']`, 'iu').exec(value)?.[1] ?? ''; }
function firstCapture(value, pattern) { return pattern.exec(value)?.[1] ?? ''; }
function strip(value) { return value.replace(/<script[\s\S]*?<\/script>/giu, '').replace(/<style[\s\S]*?<\/style>/giu, '').replace(/<[^>]+>/gu, ' ').replace(/&nbsp;/giu, ' ').replace(/&amp;/giu, '&').replace(/\s+/gu, ' ').trim(); }
function cursorPage(cursor, target) { if (cursor === null)
    return 1; const raw = cursor.startsWith(`${target}:`) ? cursor.slice(target.length + 1) : '', page = Number(raw); if (!Number.isSafeInteger(page) || page < 2 || page > 1000)
    throw new Error('Cursor is invalid.'); return page; }
function clamp(value) { return Math.max(1, Math.min(50, Math.floor(value))); }
function frozen(value) { return Object.freeze(value); }
function requireContext() { if (context === undefined)
    throw new Error('Source is not activated.'); return context; }
