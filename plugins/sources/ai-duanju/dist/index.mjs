/**
 * 每日大赛 AI 剧场原生视频数据源。
 *
 * 职责：直接解析 AI 剧场列表、搜索、详情、播放器配置和签名媒体地址。
 * 生命周期：activate 重置只含页面 HTML 的内存缓存，不保存账号或设备身份。
 * IO：网页和加密封面走 ctx.http；视频通过 ctx.resource.proxy 输出。
 * 稳定标识：作品使用 archives 数字 ID，章节使用页面内播放器序号。
 */
import { createDecipheriv } from 'node:crypto';
import { load } from 'cheerio';
const base = 'https://www.mrds.com', category = '/category/aijc/', headers = { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/126.0 Safari/537.36', Accept: 'text/html,application/xhtml+xml,*/*;q=0.8' }, key = Buffer.from('f5d965df75336270'), iv = Buffer.from('97b60394abc2fbe1');
let context;
const cache = new Map();
export async function activate(next) { context = next; cache.clear(); next.log.info('source_activated'); }
export async function search(request) { const query = clean(request.query); if (!query)
    return frozen({ items: [], nextCursor: null, totalCount: 0 }); const page = cursorPage(request.cursor, 'search'), path = `/search/${encodeURIComponent(query)}/${page > 1 ? `${page}/` : ''}`, values = parseCards(await get(path)).slice(0, clamp(request.pageSize)), items = await Promise.all(values.map(summary)); return frozen({ items, nextCursor: values.length >= clamp(request.pageSize) ? `search:${page + 1}` : null, totalCount: null }); }
export async function searchSuggestions(_request) { return frozen({ items: [], nextCursor: null }); }
export async function discover(request) { if (request.target === null)
    return frozen({ kind: 'document', document: { components: [{ type: 'section', id: 'ai-drama-channels', title: 'AI短剧', subtitle: '每日大赛 AI 剧场', icon: 'video', children: [{ type: 'categoryCollection', id: 'ai-drama-channel-list', layout: 'chips', categories: [{ id: 'theater', title: 'AI剧场', target: 'channel:theater', count: null, url: null, icon: 'video' }] }] }] } }); if (request.target !== 'channel:theater')
    throw new Error('Discovery target is invalid.'); const page = cursorPage(request.cursor, request.target), path = `${category}${page > 1 ? `${page}/` : ''}`, values = parseCards(await get(path)).slice(0, clamp(request.pageSize)), contents = await Promise.all(values.map(summary)), collectionId = 'ai-drama:theater', items = contents.map(content => frozen({ content, rank: null, metric: null, recommendation: null })), continuation = values.length >= clamp(request.pageSize) ? frozen({ target: request.target, cursor: `${request.target}:${page + 1}` }) : null; if (request.collectionId !== null) {
    if (request.collectionId !== collectionId)
        throw new Error('Discovery collection is invalid.');
    return frozen({ kind: 'append', collectionId, items, continuation });
} return frozen({ kind: 'document', document: { components: [{ type: 'section', id: `${collectionId}:section`, title: 'AI剧场', subtitle: null, icon: 'video', children: [{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation }] }] } }); }
export async function getDetail(request) { const id = contentId(request.id), html = await get(`/archives/${id}/`), $ = load(html), players = parsePlayers(html), cover = $('meta[itemprop="image"]').attr('content') ?? '', item = await summary({ id, title: clean($('meta[property="og:title"]').attr('content') ?? $('h1').first().text()) || id, author: clean($('article meta[itemprop="name"]').first().attr('content') ?? $('.post-meta a').first().text()), date: $('meta[itemprop="dateModified"]').attr('content') ?? '', cover, description: clean($('meta[property="og:description"]').attr('content') ?? $('meta[name="description"]').attr('content') ?? '') }); return frozen({ ...item, chapterCount: players.length, latestChapter: players.length ? { id: `video:${id}:${players.length - 1}`, title: players.at(-1)?.title ?? `第${players.length}段`, url: null, updatedAt: null } : null, aliases: [], catalogUrl: `${base}/archives/${id}/` }); }
export async function getChapters(request) { const id = contentId(request.id), players = parsePlayers(await get(`/archives/${id}/`)), items = players.map((player, index) => frozen({ id: `video:${id}:${index}`, title: player.title || `${players.length === 1 ? '正片' : `第${index + 1}段`}`, order: index, url: null, volumeTitle: 'AI剧场', wordCount: null, updatedAt: null, isLocked: false, attributes: [] })); return frozen({ items, groups: [frozen({ id: `group:${id}`, title: 'AI剧场', order: 0, episodes: items })] }); }
export async function getContent(request) { const id = contentId(request.id), index = chapterIndex(request.chapterId, id), players = parsePlayers(await get(`/archives/${id}/`, true)), player = players[index]; if (!player || !safeUrl(player.url))
    throw new Error('Video address is unavailable.'); const resourceType = /\.m3u8(?:$|[?#])/iu.test(player.url) ? 'hls' : 'video', mediaHeaders = { Referer: `${base}/archives/${id}/`, 'User-Agent': headers['User-Agent'] }; return frozen({ chapterId: request.chapterId, contentKind: 'video', title: player.title || null, updatedAt: null, text: null, pages: [], media: { url: requireContext().resource.proxy({ kind: resourceType, url: player.url, headers: mediaHeaders }), resourceType, resourcePolicy: 'sessionOnly', expiresAt: null, mimeType: resourceType === 'hls' ? 'application/vnd.apple.mpegurl' : 'video/mp4', headers: mediaHeaders } }); }
async function get(path, fresh = false) { const url = new URL(path, base).toString(), cached = cache.get(url); if (!fresh && cached)
    return cached; const target = fresh ? `${url}${url.includes('?') ? '&' : '?'}_t=${Date.now()}` : url, response = await requireContext().http.fetch(target, { headers }); if (!response.ok)
    throw new Error('Source request failed.'); const value = await response.text(); cache.set(url, value); return value; }
function parseCards(html) { const $ = load(html), values = new Map(); for (const node of $('article').toArray()) {
    const card = $(node), info = clean(card.find('.post-card-info').text());
    if (!info.includes('AI剧场'))
        continue;
    const path = card.find('meta[itemprop="url mainEntityOfPage"]').attr('content') ?? '', id = /\/archives\/(\d+)/u.exec(path)?.[1], title = clean(card.find('.post-card-title').text());
    if (!id || !title)
        continue;
    const raw = card.html() ?? '', cover = /loadBannerDirect\(\s*['"]([^'"]+)/iu.exec(raw)?.[1]?.replaceAll('\\/', '/') ?? '';
    values.set(id, { id, title, author: card.find('meta[itemprop="name"]').first().attr('content') ?? '', date: card.find('meta[itemprop="dateModified"]').attr('content') ?? '', cover, description: '' });
} return [...values.values()]; }
function parsePlayers(html) { const $ = load(html), values = []; for (const node of $('.dplayer').toArray()) {
    const player = $(node), raw = player.attr('data-config') ?? '';
    let data;
    try {
        data = JSON.parse(raw);
    }
    catch {
        continue;
    }
    const record = isObject(data) && isObject(data.video) ? data.video : {}, url = text(record.url);
    if (!safeUrl(url))
        continue;
    values.push({ title: clean(player.attr('data-video_title') ?? ''), url, type: text(record.type) });
} return values; }
async function summary(value) { return frozen({ id: `video:${value.id}`, title: value.title, contentKind: 'video', coverOrientation: 'landscape', author: value.author || null, url: `${base}/archives/${value.id}/`, coverUrl: await decryptedCover(value.cover), description: value.description || null, language: 'zh-CN', status: 'completed', access: 'free', wordCount: null, chapterCount: null, publishedAt: null, updatedAt: value.date || null, latestChapter: null, categories: ['AI剧场'], tags: ['短剧'], attributes: [] }); }
async function decryptedCover(url) { if (!safeUrl(url))
    return null; try {
    const response = await requireContext().http.fetch(url, { headers: { ...headers, Referer: `${base}/` } });
    if (!response.ok)
        return null;
    const encrypted = Buffer.from(await response.arrayBuffer()), decipher = createDecipheriv('aes-128-cbc', key, iv), plain = Buffer.concat([decipher.update(encrypted), decipher.final()]), mime = plain[0] === 0xff && plain[1] === 0xd8 ? 'image/jpeg' : plain[0] === 0x89 && plain[1] === 0x50 ? 'image/png' : plain.subarray(0, 4).toString() === 'RIFF' ? 'image/webp' : '';
    return mime ? `data:${mime};base64,${plain.toString('base64')}` : null;
}
catch {
    return null;
} }
function contentId(id) { const value = /^video:(\d+)$/u.exec(id)?.[1]; if (!value)
    throw new Error('Content ID is invalid.'); return value; }
function chapterIndex(id, content) { const value = Number(new RegExp(`^video:${content}:(\\d+)$`, 'u').exec(id)?.[1]); if (!Number.isSafeInteger(value) || value < 0)
    throw new Error('Chapter ID is invalid.'); return value; }
function isObject(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function text(value) { return typeof value === 'string' ? value.trim() : typeof value === 'number' ? String(value) : ''; }
function safeUrl(value) { try {
    return ['http:', 'https:'].includes(new URL(value).protocol);
}
catch {
    return false;
} }
function clean(value) { return value.replaceAll(/<[^>]+>/gu, ' ').replaceAll(/\s+/gu, ' ').trim(); }
function cursorPage(cursor, target) { if (cursor === null)
    return 1; const page = Number(cursor.startsWith(`${target}:`) ? cursor.slice(target.length + 1) : ''); if (!Number.isSafeInteger(page) || page < 2)
    throw new Error('Cursor is invalid.'); return page; }
function clamp(value) { return Math.max(1, Math.min(30, Math.floor(value))); }
function frozen(value) { return Object.freeze(value); }
function requireContext() { if (!context)
    throw new Error('Source is not activated.'); return context; }
