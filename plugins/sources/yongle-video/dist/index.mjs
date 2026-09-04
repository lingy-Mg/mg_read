const base = 'https://www.ylsp.lv', headers = Object.freeze({ Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8', 'Accept-Language': 'zh-CN,zh;q=0.9', Referer: `${base}/`, 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/136.0.0.0' }), categories = Object.freeze([['home', '首页', '/'], ['movie', '电影', '/vodtype/1/'], ['series', '剧集', '/vodtype/2/'], ['variety', '综艺', '/vodtype/3/'], ['anime', '动漫', '/vodtype/4/'], ['new', '更新', '/label/new/'], ['hot', '热榜', '/label/hot/']]);
let context;
export async function activate(next) { context = next; next.log.info('source_activated'); }
export async function search(request) { const query = request.query.trim(); if (query === '')
    return frozen({ items: [], nextCursor: null, totalCount: 0 }); const page = cursorPage(request.cursor, 'search'), limit = clamp(request.pageSize), path = page === 1 ? `/vodsearch/${encodeURIComponent(query)}-------------/` : `/vodsearch/${encodeURIComponent(query)}----------${page}---/`, values = parseList(await fetchText(`${base}${path}`)).slice(0, limit); return frozen({ items: values, nextCursor: values.length >= limit ? `search:${page + 1}` : null, totalCount: null }); }
export async function searchSuggestions(_request) { return frozen({ items: [], nextCursor: null }); }
export async function discover(request) { if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null)
        throw new Error('Initial discovery request is invalid.');
    return frozen({ kind: 'document', document: { components: [{ type: 'section', id: 'video-categories', title: '影视分类', subtitle: '按频道浏览', icon: 'video', children: [{ type: 'categoryCollection', id: 'video-categories-list', layout: 'chips', categories: categories.map(([id, title]) => ({ id, title, target: `category:${id}`, count: null, url: null, icon: 'video' })) }] }] } });
} const category = categories.find(([id]) => request.target === `category:${id}`); if (category === undefined)
    throw new Error('Discovery target is invalid.'); const page = cursorPage(request.cursor, request.target), limit = clamp(request.pageSize), [id, title, path] = category, values = parseList(await fetchText(pageUrl(path, page))).slice(0, limit), collectionId = `video:${id}`, items = values.map(content => frozen({ content, rank: null, metric: null, recommendation: null })), continuation = values.length >= limit ? frozen({ target: request.target, cursor: `${request.target}:${page + 1}` }) : null; if (request.collectionId !== null) {
    if (request.collectionId !== collectionId)
        throw new Error('Discovery collection is invalid.');
    return frozen({ kind: 'append', collectionId, items, continuation });
} return frozen({ kind: 'document', document: { components: [{ type: 'section', id: `${collectionId}:section`, title, subtitle: null, icon: 'video', children: [{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation }] }] } }); }
export async function getDetail(request) { const id = contentId(request.id), html = await fetchText(detailUrl(id)), title = firstText(html, /<div[^>]*class=["'][^"']*module-info-heading[^"']*["'][^>]*>[\s\S]*?<h1[^>]*>([\s\S]*?)<\/h1>/iu) || firstAttribute(html, /<meta[^>]*property=["']og:title["'][^>]*>/iu, 'content') || `视频 ${id}`, cover = firstAttribute(html, /<meta[^>]*property=["']og:image["'][^>]*>/iu, 'content'), description = firstText(html, /<[^>]*class=["'][^"']*module-info-introduction-content[^"']*["'][^>]*>([\s\S]*?)<\/[^>]+>/iu), item = summary(id, title, cover); return frozen({ ...item, description: description || null, aliases: [], catalogUrl: item.url }); }
export async function getChapters(request) { const id = contentId(request.id), links = parsePlayLinks(await fetchText(detailUrl(id))).filter(link => link.id === id), bySid = new Map(); for (const link of links) {
    const values = bySid.get(link.sid) ?? [];
    values.push(link);
    bySid.set(link.sid, values);
} const groups = [...bySid.entries()].map(([sid, values], index) => { const title = `线路${index + 1}`, episodes = values.map((link, order) => frozen({ id: `video:${id}:${sid}:${link.nid}`, title: link.title || `第${order + 1}集`, order, url: playUrl(id, sid, link.nid), volumeTitle: title, wordCount: null, updatedAt: null, isLocked: null, attributes: [] })); return frozen({ id: `group:${id}:${sid}`, title, order: index, episodes }); }); return frozen({ items: groups.flatMap(group => group.episodes), groups }); }
export async function getContent(request) { const id = contentId(request.id), chapter = parseChapterId(request.chapterId, id), page = playUrl(id, chapter.sid, chapter.nid), data = parsePlayer(await fetchText(page)); let upstream = text(data.url).replaceAll('\\/', '/'); const encrypt = Number(data.encrypt ?? 0); if (encrypt === 2) {
    upstream = Buffer.from(upstream, 'base64').toString('utf8');
    try {
        upstream = decodeURIComponent(upstream);
    }
    catch { }
}
else if (encrypt === 1) {
    try {
        upstream = decodeURIComponent(upstream);
    }
    catch { }
} if (!safeUrl(upstream))
    throw new Error('Playback address is unavailable.'); const resourceType = /\.m3u8(?:$|[?#])/iu.test(upstream) ? 'hls' : 'video', mediaHeaders = { Origin: base, Referer: page, 'User-Agent': headers['User-Agent'] }; return frozen({ chapterId: request.chapterId, contentKind: 'video', title: null, updatedAt: null, text: null, pages: [], media: { url: requireContext().resource.proxy({ kind: resourceType, url: upstream, headers: mediaHeaders }), resourceType, resourcePolicy: 'sessionOnly', expiresAt: null, mimeType: resourceType === 'hls' ? 'application/vnd.apple.mpegurl' : 'video/mp4', headers: mediaHeaders } }); }
async function fetchText(url) { const response = await requireContext().http.fetch(url, { headers }); if (!response.ok)
    throw new Error('Source request failed.'); return response.text(); }
function parseList(html) { const values = new Map(); for (const match of html.matchAll(/<a\b([^>]*)href=["']([^"']*\/voddetail\/(\d+)\/)["']([^>]*)>([\s\S]*?)<\/a>/giu)) {
    const id = match[3] ?? '', attrs = `${match[1] ?? ''} ${match[4] ?? ''}`, body = match[5] ?? '', image = /<img\b[^>]*>/iu.exec(body)?.[0] ?? '', title = attribute(attrs, 'title') || attribute(image, 'alt') || strip(body) || `视频 ${id}`, cover = attribute(image, 'data-original') || attribute(image, 'data-src') || attribute(image, 'src');
    if (id !== '' && !values.has(id))
        values.set(id, summary(id, title, cover));
} return [...values.values()]; }
function parsePlayLinks(html) { const result = []; for (const match of html.matchAll(/<a\b([^>]*)href=["']([^"']*\/vodplay\/(\d+)-(\d+)-(\d+)\/)["']([^>]*)>([\s\S]*?)<\/a>/giu)) {
    if (match[3] && match[4] && match[5])
        result.push({ id: match[3], sid: match[4], nid: match[5], title: attribute(`${match[1] ?? ''} ${match[6] ?? ''}`, 'title') || strip(match[7] ?? '') });
} return result; }
function parsePlayer(html) { const start = html.search(/(?:var\s+)?player_\w+\s*=\s*\{/iu); if (start < 0)
    throw new Error('Player data is unavailable.'); const brace = html.indexOf('{', start), raw = balancedObject(html, brace), value = JSON.parse(raw); if (!isObject(value))
    throw new Error('Player data is invalid.'); return value; }
function balancedObject(value, start) { let depth = 0, quote = '', escaped = false; for (let index = start; index < value.length; index += 1) {
    const char = value[index] ?? '';
    if (quote !== '') {
        if (escaped)
            escaped = false;
        else if (char === '\\')
            escaped = true;
        else if (char === quote)
            quote = '';
        continue;
    }
    if (char === '"' || char === "'") {
        quote = char;
        continue;
    }
    if (char === '{')
        depth += 1;
    if (char === '}') {
        depth -= 1;
        if (depth === 0)
            return value.slice(start, index + 1);
    }
} throw new Error('Player data is incomplete.'); }
function summary(id, title, cover) { return frozen({ id: `video:${id}`, title: decode(title) || `视频 ${id}`, contentKind: 'video', coverOrientation: 'portrait', author: null, url: detailUrl(id), coverUrl: proxyImage(cover), description: null, language: 'zh-CN', status: 'unknown', access: 'unknown', wordCount: null, chapterCount: null, publishedAt: null, updatedAt: null, latestChapter: null, categories: [], tags: [], attributes: [] }); }
function pageUrl(path, page) { if (page <= 1)
    return `${base}${path}`; if (path === '/')
    return `${base}/index-${page}.html`; return `${base}${path.replace(/\/$/u, '')}-${page}/`; }
function detailUrl(id) { return `${base}/voddetail/${id}/`; }
function playUrl(id, sid, nid) { return `${base}/vodplay/${id}-${sid}-${nid}/`; }
function contentId(id) { const value = /^video:(\d+)$/u.exec(id)?.[1]; if (value === undefined)
    throw new Error('Content ID is invalid.'); return value; }
function parseChapterId(id, content) { const match = new RegExp(`^video:${content}:(\\d+):(\\d+)$`, 'u').exec(id); if (!match?.[1] || !match[2])
    throw new Error('Chapter ID is invalid.'); return { sid: match[1], nid: match[2] }; }
function proxyImage(value) { const url = absolute(value); return url === null ? null : requireContext().resource.proxy({ kind: 'image', url, headers: { Referer: `${base}/` } }); }
function absolute(value) { if (value === '')
    return null; try {
    return new URL(decode(value), base).toString();
}
catch {
    return null;
} }
function safeUrl(value) { try {
    const url = new URL(value);
    return (url.protocol === 'https:' || url.protocol === 'http:') && url.username === '' && url.password === '';
}
catch {
    return false;
} }
function attribute(value, name) { return new RegExp(`${name}=["']([^"']+)["']`, 'iu').exec(value)?.[1] ?? ''; }
function firstAttribute(html, pattern, name) { const match = pattern.exec(html); return match === null ? '' : attribute(match[0], name); }
function firstText(html, pattern) { return strip(pattern.exec(html)?.[1] ?? ''); }
function strip(value) { return decode(value.replace(/<script[\s\S]*?<\/script>/giu, '').replace(/<style[\s\S]*?<\/style>/giu, '').replace(/<[^>]+>/gu, ' ').replace(/\s+/gu, ' ')).trim(); }
function decode(value) { return value.replace(/&amp;/giu, '&').replace(/&quot;/giu, '"').replace(/&#39;/giu, "'").replace(/&lt;/giu, '<').replace(/&gt;/giu, '>').replace(/&nbsp;/giu, ' '); }
function cursorPage(cursor, target) { if (cursor === null)
    return 1; const raw = cursor.startsWith(`${target}:`) ? cursor.slice(target.length + 1) : '', page = Number(raw); if (!Number.isSafeInteger(page) || page < 2 || page > 1000)
    throw new Error('Cursor is invalid.'); return page; }
function clamp(value) { return Math.max(1, Math.min(50, Math.floor(value))); }
function text(value) { return typeof value === 'string' ? value.trim() : typeof value === 'number' ? String(value) : ''; }
function isObject(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function frozen(value) { return Object.freeze(value); }
function requireContext() { if (context === undefined)
    throw new Error('Source is not activated.'); return context; }
