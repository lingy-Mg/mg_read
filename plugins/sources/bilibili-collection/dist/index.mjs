const api = 'https://api.bilibili.com', web = 'https://www.bilibili.com', ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36', channels = ['首页', '动画', '音乐', '影视', '科技', '游戏', '知识'];
let context, cookiePromise;
export async function activate(next) { context = next; cookiePromise = undefined; next.log.info('source_activated'); }
export async function search(request) { const query = clean(request.query); if (!query)
    return frozen({ items: [], nextCursor: null, totalCount: 0 }); const page = cursorPage(request.cursor, 'search'), json = await getJson(`/x/web-interface/search/type?search_type=video&keyword=${encodeURIComponent(query)}&page=${page}`), data = object(json.data), values = records(data.result).map(summary).filter(notNull).slice(0, clamp(request.pageSize)); return frozen({ items: values, nextCursor: values.length >= clamp(request.pageSize) ? `search:${page + 1}` : null, totalCount: number(data.numResults) || null }); }
export async function searchSuggestions(_request) { return frozen({ items: [], nextCursor: null }); }
export async function discover(request) { if (request.target === null)
    return frozen({ kind: 'document', document: { components: [{ type: 'section', id: 'bili-channels', title: '哔哩集合', subtitle: 'Bilibili 匿名浏览', icon: 'video', children: [{ type: 'categoryCollection', id: 'bili-channel-list', layout: 'chips', categories: channels.map((title, index) => ({ id: String(index), title, target: `channel:${index}`, count: null, url: null, icon: 'video' })) }] }] } }); const index = Number(request.target.replace(/^channel:/u, '')), title = channels[index]; if (!Number.isSafeInteger(index) || !title)
    throw new Error('Discovery target is invalid.'); const page = cursorPage(request.cursor, request.target); let values = []; if (index === 0) {
    const json = await getJson('/x/web-interface/ranking/v2?rid=0&type=all'), data = object(json.data);
    values = records(data.list);
}
else {
    const json = await getJson(`/x/web-interface/search/type?search_type=video&keyword=${encodeURIComponent(title)}&page=${page}`), data = object(json.data);
    values = records(data.result);
} const size = clamp(request.pageSize), contents = values.map(summary).filter(notNull).slice(0, size), collectionId = `bili:${index}`, items = contents.map(content => frozen({ content, rank: null, metric: null, recommendation: null })), continuation = index > 0 && contents.length >= size ? frozen({ target: request.target, cursor: `${request.target}:${page + 1}` }) : null; if (request.collectionId !== null) {
    if (request.collectionId !== collectionId || index === 0)
        throw new Error('Discovery collection is invalid.');
    return frozen({ kind: 'append', collectionId, items, continuation });
} return frozen({ kind: 'document', document: { components: [{ type: 'section', id: `${collectionId}:section`, title, subtitle: null, icon: 'video', children: [{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation }] }] } }); }
export async function getDetail(request) { const bvid = contentId(request.id), data = object((await getJson(`/x/web-interface/view?bvid=${encodeURIComponent(bvid)}`)).data), pages = pageModels(data, bvid), item = summary(data); if (!item)
    throw new Error('Video detail is unavailable.'); return frozen({ ...item, chapterCount: pages.length, latestChapter: pages.length ? { id: chapterId(bvid, pages.at(-1)), title: pages.at(-1)?.title ?? '', url: null, updatedAt: null } : null, aliases: [], catalogUrl: `${web}/video/${bvid}` }); }
export async function getChapters(request) { const bvid = contentId(request.id), data = object((await getJson(`/x/web-interface/view?bvid=${encodeURIComponent(bvid)}`)).data), pages = pageModels(data, bvid), items = pages.map((page, index) => frozen({ id: chapterId(bvid, page), title: page.title, order: index, url: null, volumeTitle: '默认线路', wordCount: null, updatedAt: null, isLocked: false, attributes: [] })); return frozen({ items, groups: [frozen({ id: `group:${bvid}`, title: '默认线路', order: 0, episodes: items })] }); }
export async function getContent(request) { const bvid = contentId(request.id), key = chapterKey(request.chapterId, bvid), data = object((await getJson(`/x/player/playurl?avid=${encodeURIComponent(key.aid)}&cid=${encodeURIComponent(key.cid)}&qn=80&fnval=0&fourk=1`)).data), durl = records(data.durl)[0], backups = Array.isArray(durl?.backup_url) ? durl.backup_url : [], candidate = backups.find(value => typeof value === 'string' && (value.includes('bilivideo.com') || value.includes('upos'))) ?? durl?.url, upstream = text(candidate); if (!safeUrl(upstream))
    throw new Error('Video address is unavailable.'); const mediaHeaders = { Referer: `${web}/video/${bvid}`, 'User-Agent': ua, Origin: web, Accept: '*/*', Cookie: await anonymousCookie() }; return frozen({ chapterId: request.chapterId, contentKind: 'video', title: null, updatedAt: null, text: null, pages: [], media: { url: requireContext().resource.proxy({ kind: 'video', url: upstream, headers: mediaHeaders }), resourceType: 'video', resourcePolicy: 'sessionOnly', expiresAt: null, mimeType: 'video/mp4', headers: mediaHeaders } }); }
async function getJson(path) { const response = await requireContext().http.fetch(`${api}${path}`, { headers: { 'User-Agent': ua, Referer: `${web}/`, Origin: web, Accept: 'application/json, text/plain, */*', Cookie: await anonymousCookie() } }); if (!response.ok)
    throw new Error('Bilibili request failed.'); let value; try {
    value = await response.json();
}
catch {
    throw new Error('Bilibili response is invalid.');
} if (!isObject(value) || number(value.code) !== 0)
    throw new Error(`Bilibili API error ${number(isObject(value) ? value.code : -1)}.`); return value; }
async function anonymousCookie() { if (!cookiePromise)
    cookiePromise = (async () => { try {
        const response = await requireContext().http.fetch(`${api}/x/frontend/finger/spi`, { headers: { 'User-Agent': ua, Referer: `${web}/` } }), json = await response.json(), data = isObject(json) ? object(json.data) : {}, b3 = text(data.b_3 || data.b3), b4 = text(data.b_4 || data.b4), parts = [];
        if (b3)
            parts.push(`buvid3=${b3}`);
        if (b4)
            parts.push(`buvid4=${b4}`);
        parts.push(`b_nut=${Math.floor(Date.now() / 1000)}`, 'CURRENT_FNVAL=4048');
        return parts.join('; ');
    }
    catch {
        return 'CURRENT_FNVAL=4048';
    } })(); return cookiePromise; }
function summary(value) { const bvid = text(value.bvid); if (!/^BV[0-9A-Za-z]+$/u.test(bvid))
    return null; const owner = object(value.owner), title = clean(text(value.title || value.name)); if (!title)
    return null; const cover = absoluteImage(text(value.pic || value.cover)); return frozen({ id: `video:${bvid}`, title, contentKind: 'video', coverOrientation: 'landscape', author: text(value.author || owner.name) || null, url: `${web}/video/${bvid}`, coverUrl: cover ? requireContext().resource.proxy({ kind: 'image', url: cover, headers: { Referer: `${web}/` } }) : null, description: clean(text(value.description || value.desc)) || null, language: 'zh-CN', status: 'completed', access: 'free', wordCount: null, chapterCount: null, publishedAt: timestamp(value.pubdate), updatedAt: null, latestChapter: null, categories: text(value.tname) ? [text(value.tname)] : [], tags: [], attributes: [] }); }
function pageModels(data, bvid) { const aid = text(data.aid), pages = records(data.pages).map((value, index) => ({ aid, cid: text(value.cid), title: text(value.part) || `P${index + 1}` })).filter(value => /^\d+$/u.test(value.aid) && /^\d+$/u.test(value.cid)); if (!pages.length && /^\d+$/u.test(text(data.cid)))
    pages.push({ aid, cid: text(data.cid), title: '正片' }); if (!pages.length)
    throw new Error(`No pages for ${bvid}.`); return pages; }
function chapterId(bvid, page) { return `video:${bvid}:${page.aid}:${page.cid}`; }
function chapterKey(id, bvid) { const match = new RegExp(`^video:${bvid}:(\\d+):(\\d+)$`, 'u').exec(id); if (!match)
    throw new Error('Chapter ID is invalid.'); return { aid: match[1] ?? '', cid: match[2] ?? '' }; }
function contentId(id) { const value = /^video:(BV[0-9A-Za-z]+)$/u.exec(id)?.[1]; if (!value)
    throw new Error('Content ID is invalid.'); return value; }
function absoluteImage(value) { return value.startsWith('//') ? `https:${value}` : safeUrl(value) ? value : ''; }
function clean(value) { return value.replaceAll(/<[^>]+>/gu, '').replaceAll('&quot;', '"').replaceAll('&amp;', '&').replaceAll(/\s+/gu, ' ').trim(); }
function timestamp(value) { const seconds = number(value); return seconds > 0 ? new Date(seconds * 1000).toISOString() : null; }
function object(value) { return isObject(value) ? value : {}; }
function records(value) { return Array.isArray(value) ? value.filter(isObject) : []; }
function isObject(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function number(value) { return typeof value === 'number' && Number.isFinite(value) ? value : typeof value === 'string' ? Number(value) || 0 : 0; }
function text(value) { return typeof value === 'string' ? value.trim() : typeof value === 'number' ? String(value) : ''; }
function safeUrl(value) { try {
    return ['http:', 'https:'].includes(new URL(value).protocol);
}
catch {
    return false;
} }
function notNull(value) { return value !== null; }
function cursorPage(cursor, target) { if (cursor === null)
    return 1; const page = Number(cursor.startsWith(`${target}:`) ? cursor.slice(target.length + 1) : ''); if (!Number.isSafeInteger(page) || page < 2)
    throw new Error('Cursor is invalid.'); return page; }
function clamp(value) { return Math.max(1, Math.min(50, Math.floor(value))); }
function frozen(value) { return Object.freeze(value); }
function requireContext() { if (!context)
    throw new Error('Source is not activated.'); return context; }
