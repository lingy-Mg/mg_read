const base = 'https://feza.uuss.uk', headers = Object.freeze({ Accept: 'text/html,application/xhtml+xml,application/json,*/*', 'Accept-Language': 'zh-CN,zh;q=0.9', 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0.0.0 Safari/537.36', Referer: `${base}/` }), categories = Object.freeze([['recent', 'Recently Updated', '/'], ['popular', 'Popular', '/popular/'], ['cosplay', 'Cosplay', '/cosplay/'], ['ai', 'AI Enhanced', '/tag/ai-enhanced/'], ['aigirl', 'AIGirl', '/tag/aigirl/'], ['coser', 'Coser', '/tag/coser/'], ['rosi', 'Rosi', '/tag/rosi/'], ['youxi', 'Youxi', '/tag/youxi/']]);
let context;
export async function activate(next) { context = next; next.log.info('source_activated'); }
export async function search(request) { const query = request.query.trim(); if (query === '')
    return frozen({ items: [], nextCursor: null, totalCount: 0 }); const page = cursorPage(request.cursor, 'search'), size = clamp(request.pageSize), url = `${base}/search/${encodeURIComponent(query)}/${page > 1 ? `page/${page}/` : ''}`, html = await fetchText(url), parsed = parseList(html); const values = parsed.length > 0 ? parsed.slice(0, size) : (await fetchPosts(page, size, query)).slice(0, size); return frozen({ items: values, nextCursor: values.length >= size ? `search:${page + 1}` : null, totalCount: null }); }
export async function searchSuggestions(_request) { return frozen({ items: [], nextCursor: null }); }
export async function discover(request) { if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null)
        throw new Error('Initial discovery request is invalid.');
    return frozen({ kind: 'document', document: { components: [{ type: 'section', id: 'photo-categories', title: '4KHD', subtitle: '写真与图集分类', icon: 'manga', children: [{ type: 'categoryCollection', id: 'photo-category-list', layout: 'chips', categories: categories.map(([id, title]) => ({ id, title, target: `category:${id}`, count: null, url: null, icon: 'manga' })) }] }] } });
} const category = categories.find(([id]) => request.target === `category:${id}`); if (category === undefined)
    throw new Error('Discovery target is invalid.'); const page = cursorPage(request.cursor, request.target), size = clamp(request.pageSize), pagePath = page === 1 ? category[2] : category[2] === '/' ? `/page/${page}/` : `${category[2]}page/${page}/`, html = await fetchText(`${base}${pagePath}`), parsed = parseList(html), values = parsed.length > 0 ? parsed.slice(0, size) : (await fetchPosts(page, size, '')).slice(0, size), collectionId = `manga:${category[0]}`, items = values.map(content => frozen({ content, rank: null, metric: null, recommendation: null })), continuation = values.length >= size ? frozen({ target: request.target, cursor: `${request.target}:${page + 1}` }) : null; if (request.collectionId !== null) {
    if (request.collectionId !== collectionId)
        throw new Error('Discovery collection is invalid.');
    return frozen({ kind: 'append', collectionId, items, continuation });
} return frozen({ kind: 'document', document: { components: [{ type: 'section', id: `${collectionId}:section`, title: category[1], subtitle: null, icon: 'manga', children: [{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation }] }] } }); }
export async function getDetail(request) { const path = contentPath(request.id), url = `${base}${path}`, html = await fetchText(url), title = decode(strip(firstCapture(html, /<title[^>]*>([^<]+)<\/title>/iu)).replace(/\s*-\s*4KHD\s*$/iu, '').trim()) || 'Photo', cover = firstCapture(html, /<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']/iu) || firstCapture(html, /<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:image["']/iu), description = decode(firstCapture(html, /<meta[^>]+(?:property=["']og:description["']|name=["']description["'])[^>]+content=["']([^"']+)["']/iu)), item = summary(path, title, cover); return frozen({ ...item, description: description || null, aliases: [], catalogUrl: url }); }
export async function getChapters(request) { const path = contentPath(request.id), chapter = frozen({ id: `manga:${encodeKey(path)}:main`, title: 'Full Album', order: 0, url: null, volumeTitle: 'Album', wordCount: null, updatedAt: null, isLocked: null, attributes: [] }); return frozen({ items: [chapter], groups: [frozen({ id: `group:manga:${encodeKey(path)}`, title: 'Album', order: 0, episodes: [chapter] })] }); }
export async function getContent(request) { const path = contentPath(request.id); if (request.chapterId !== `manga:${encodeKey(path)}:main`)
    throw new Error('Chapter ID is invalid.'); const seenPages = new Set(), seenImages = new Set(), images = []; let current = `${base}${path}`; for (let page = 0; page < 40 && current !== '' && !seenPages.has(current); page += 1) {
    seenPages.add(current);
    const html = await fetchText(current);
    for (const image of extractImages(html))
        if (!seenImages.has(image)) {
            seenImages.add(image);
            images.push(image);
        }
    const next = firstCapture(html, /<link[^>]+rel=["']next["'][^>]+href=["']([^"']+)["']/iu) || firstCapture(html, /<link[^>]+href=["']([^"']+)["'][^>]+rel=["']next["']/iu);
    current = next === '' ? '' : new URL(next, current).toString();
} if (images.length === 0)
    throw new Error('Album images are unavailable.'); const pages = images.map((upstream, index) => frozen({ id: `page:${index + 1}`, index, url: requireContext().resource.proxy({ kind: 'image', url: upstream, headers: { Referer: `${base}${path}` } }), mimeType: imageMime(upstream), width: null, height: null })); return frozen({ chapterId: request.chapterId, contentKind: 'manga', title: null, updatedAt: null, text: null, pages: Object.freeze(pages) }); }
async function fetchPosts(page, size, query) { const url = new URL(`${base}/wp-json/wp/v2/posts`); url.searchParams.set('per_page', String(size)); url.searchParams.set('page', String(page)); if (query !== '')
    url.searchParams.set('search', query); const response = await requireContext().http.fetch(url, { headers }); if (!response.ok)
    return []; let value; try {
    value = await response.json();
}
catch {
    return [];
} if (!Array.isArray(value))
    return []; return value.filter(isObject).map(post => { const path = normalizePath(text(post.link)); if (path === null)
    return null; const title = decode(strip(text(object(post.title).rendered))) || `Photo ${text(post.id)}`, cover = text(post.jetpack_featured_media_url); return summary(path, title, cover); }).filter(notNull); }
async function fetchText(url) { const response = await requireContext().http.fetch(url, { headers }); if (!response.ok)
    throw new Error('Source request failed.'); return response.text(); }
function parseList(html) { const values = new Map(); for (const match of html.matchAll(/<a\b([^>]*)href=["']([^"']*\/(?:content|album|pic)\/[^"']+)["']([^>]*)>([\s\S]*?)<\/a>/giu)) {
    const path = normalizePath(match[2] ?? '');
    if (path === null || values.has(path))
        continue;
    const body = match[4] ?? '', image = /<img\b[^>]*>/iu.exec(body)?.[0] ?? '', title = strip(firstCapture(body, /<h2[^>]*>([\s\S]*?)<\/h2>/iu)) || attribute(`${match[1] ?? ''} ${match[3] ?? ''}`, 'title') || strip(body);
    if (title === '')
        continue;
    values.set(path, summary(path, decode(title), attribute(image, 'src')));
} return [...values.values()]; }
function extractImages(html) { const end = html.indexOf('id="basicE"'), start = html.indexOf('<p><a href="https://i'), gallery = start >= 0 ? html.slice(start, end >= 0 ? end : undefined) : html, values = []; for (const match of gallery.matchAll(/<a[^>]+href=["'](https:\/\/i\d+\.wp\.com\/pic\.4khd\.com\/[^?"'\s]+)["'][^>]*>\s*<img/giu))
    if (match[1])
        values.push(match[1]); if (values.length === 0)
    for (const match of gallery.matchAll(/<img[^>]+src=["'](https:\/\/i\d+\.wp\.com\/pic\.4khd\.com\/[^?"'\s]+)/giu))
        if (match[1])
            values.push(match[1]); return values; }
function summary(path, title, cover) { return frozen({ id: `manga:${encodeKey(path)}`, title, contentKind: 'manga', coverOrientation: 'portrait', author: null, url: `${base}${path}`, coverUrl: proxyImage(cover), description: null, language: null, status: 'completed', access: 'free', wordCount: null, chapterCount: 1, publishedAt: null, updatedAt: null, latestChapter: { id: `manga:${encodeKey(path)}:main`, title: 'Full Album', url: null, updatedAt: null }, categories: ['Photo'], tags: [], attributes: [] }); }
function normalizePath(value) { if (value === '')
    return null; try {
    const url = new URL(value, base);
    if (!['/content/', '/album/', '/pic/'].some(prefix => url.pathname.startsWith(prefix)))
        return null;
    return url.pathname;
}
catch {
    return null;
} }
function contentPath(id) { const encoded = /^manga:([A-Za-z0-9_-]+)$/u.exec(id)?.[1]; if (encoded === undefined)
    throw new Error('Content ID is invalid.'); const path = decodeKey(encoded); if (normalizePath(path) !== path)
    throw new Error('Content ID is invalid.'); return path; }
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
function imageMime(url) { const path = new URL(url).pathname.toLowerCase(); return path.endsWith('.png') ? 'image/png' : path.endsWith('.webp') ? 'image/webp' : 'image/jpeg'; }
function attribute(value, name) { return new RegExp(`${name}=["']([^"']+)["']`, 'iu').exec(value)?.[1] ?? ''; }
function firstCapture(value, pattern) { return pattern.exec(value)?.[1] ?? ''; }
function strip(value) { return value.replace(/<[^>]+>/gu, ' ').replace(/\s+/gu, ' ').trim(); }
function decode(value) { return value.replace(/&#8211;/gu, '–').replace(/&#038;|&amp;/gu, '&').replace(/&quot;/gu, '"').replace(/&#39;/gu, "'"); }
function cursorPage(cursor, target) { if (cursor === null)
    return 1; const raw = cursor.startsWith(`${target}:`) ? cursor.slice(target.length + 1) : '', page = Number(raw); if (!Number.isSafeInteger(page) || page < 2 || page > 1000)
    throw new Error('Cursor is invalid.'); return page; }
function object(value) { return isObject(value) ? value : {}; }
function isObject(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function text(value) { return typeof value === 'string' ? value.trim() : typeof value === 'number' ? String(value) : ''; }
function notNull(value) { return value !== null; }
function clamp(value) { return Math.max(1, Math.min(50, Math.floor(value))); }
function frozen(value) { return Object.freeze(value); }
function requireContext() { if (context === undefined)
    throw new Error('Source is not activated.'); return context; }
