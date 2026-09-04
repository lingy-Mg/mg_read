/**
 * 麦田影院原生视频数据源。
 *
 * 职责：直接解析站点类型页、搜索接口、详情、线路及 player_data。
 * 生命周期：activate 只保存 Runtime 上下文并清空页面缓存。
 * IO：页面和 JSON 走 ctx.http，封面与媒体统一经 ctx.resource.proxy。
 * 稳定标识：作品使用 vod 数字 ID，章节使用站内线路号和集号。
 */
import { load } from 'cheerio';
const base = 'https://www.mtyy7.com', headers = { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/125.0 Safari/537.36', Accept: 'text/html,application/xhtml+xml,application/json,*/*;q=0.8', Referer: `${base}/` }, channels = [['26', '短剧'], ['1', '电影'], ['2', '电视剧'], ['4', '动漫'], ['3', '综艺']];
let context;
const cache = new Map();
export async function activate(next) { context = next; cache.clear(); next.log.info('source_activated'); }
export async function search(request) { if (request.cursor !== null)
    throw new Error('Cursor is invalid.'); const query = clean(request.query); if (!query)
    return frozen({ items: [], nextCursor: null, totalCount: 0 }); const raw = await get(`/index.php/ajax/suggest?mid=1&wd=${encodeURIComponent(query)}&limit=${clamp(request.pageSize)}`); let value; try {
    value = JSON.parse(raw);
}
catch {
    value = null;
} const records = isObject(value) && Array.isArray(value.list) ? value.list.filter(isObject) : [], items = records.map(entry => summary({ id: text(entry.id), title: text(entry.name), cover: absolute(text(entry.pic)), remark: '', category: '' })).filter(notNull); return frozen({ items, nextCursor: null, totalCount: items.length }); }
export async function searchSuggestions(_request) { return frozen({ items: [], nextCursor: null }); }
export async function discover(request) { if (request.target === null)
    return frozen({ kind: 'document', document: { components: [{ type: 'section', id: 'maitian-channels', title: '麦田影院', subtitle: '影视分类', icon: 'video', children: [{ type: 'categoryCollection', id: 'maitian-channel-list', layout: 'chips', categories: channels.map(([id, title]) => ({ id, title, target: `channel:${id}`, count: null, url: null, icon: 'video' })) }] }] } }); if (request.cursor !== null)
    throw new Error('Cursor is invalid.'); const channel = channels.find(([id]) => request.target === `channel:${id}`); if (!channel)
    throw new Error('Discovery target is invalid.'); const values = parseList(await get(`/vodtype/${channel[0]}.html`)).slice(0, clamp(request.pageSize)), contents = values.map(value => summary({ ...value, category: channel[1] })).filter(notNull), collectionId = `maitian:${channel[0]}`, items = contents.map(content => frozen({ content, rank: null, metric: null, recommendation: null })); if (request.collectionId !== null)
    throw new Error('Discovery has no continuation.'); return frozen({ kind: 'document', document: { components: [{ type: 'section', id: `${collectionId}:section`, title: channel[1], subtitle: null, icon: 'video', children: [{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation: null }] }] } }); }
export async function getDetail(request) { const id = contentId(request.id), html = await get(`/voddetail/${id}.html`), $ = load(html), episodes = parseEpisodes(html), style = $('.this-pic-bj').attr('style') ?? '', cover = /url\(["']?([^"')]+)/iu.exec(style)?.[1] ?? '', title = clean($('.this-desc-title').first().text()) || id, description = clean($('#height_limit').first().text()).replace(/^描述[:：]\s*/u, ''), category = clean($('.focus-item-label-original').first().text()), remark = clean($('.this-desc-info span').last().text()), item = summary({ id, title, cover: absolute(cover), remark, category }); if (!item)
    throw new Error('Video detail is unavailable.'); return frozen({ ...item, description: description || null, chapterCount: episodes.length, latestChapter: episodes.length ? { id: episodeId(id, episodes.at(-1)), title: episodes.at(-1)?.title ?? '', url: null, updatedAt: null } : null, aliases: [], catalogUrl: `${base}/voddetail/${id}.html` }); }
export async function getChapters(request) { const id = contentId(request.id), episodes = parseEpisodes(await get(`/voddetail/${id}.html`)), items = episodes.map((episode, index) => frozen({ id: episodeId(id, episode), title: episode.title, order: index, url: null, volumeTitle: episode.group, wordCount: null, updatedAt: null, isLocked: false, attributes: [] })), groups = [...new Set(episodes.map(value => value.group))].map((title, index) => frozen({ id: `group:${id}:${index}`, title, order: index, episodes: items.filter(item => item.volumeTitle === title) })); return frozen({ items, groups }); }
export async function getContent(request) { const id = contentId(request.id), episode = chapterKey(request.chapterId, id), page = `${base}/vodplay/${id}-${episode.line}-${episode.number}.html`, html = await get(page, true), raw = extractObject(html, 'player_data'); if (!raw)
    throw new Error('Player data is unavailable.'); let data; try {
    data = JSON.parse(raw);
}
catch {
    throw new Error('Player data is invalid.');
} let upstream = isObject(data) ? text(data.url).replaceAll('\\/', '/') : ''; const encrypt = Number(isObject(data) ? data.encrypt : 0); if (encrypt === 2) {
    try {
        upstream = decodeURIComponent(Buffer.from(upstream, 'base64').toString('utf8'));
    }
    catch {
        throw new Error('Player data is invalid.');
    }
}
else if (encrypt === 1)
    try {
        upstream = decodeURIComponent(upstream);
    }
    catch { } if (!safeUrl(upstream))
    throw new Error('Video address is unavailable.'); const resourceType = /\.m3u8(?:$|[?#])/iu.test(upstream) ? 'hls' : 'video', mediaHeaders = { Referer: page, 'User-Agent': headers['User-Agent'] }; return frozen({ chapterId: request.chapterId, contentKind: 'video', title: null, updatedAt: null, text: null, pages: [], media: { url: requireContext().resource.proxy({ kind: resourceType, url: upstream, headers: mediaHeaders }), resourceType, resourcePolicy: 'sessionOnly', expiresAt: null, mimeType: resourceType === 'hls' ? 'application/vnd.apple.mpegurl' : 'video/mp4', headers: mediaHeaders } }); }
async function get(path, fresh = false) { const url = safeUrl(path) ? path : new URL(path, base).toString(), cached = cache.get(url); if (!fresh && cached)
    return cached; const target = fresh ? `${url}${url.includes('?') ? '&' : '?'}_t=${Date.now()}` : url, response = await requireContext().http.fetch(target, { headers }); if (!response.ok)
    throw new Error('Source request failed.'); let value = await response.text(); if (value.startsWith('"'))
    try {
        const decoded = JSON.parse(value);
        if (typeof decoded === 'string')
            value = decoded;
    }
    catch { } cache.set(url, value); return value; }
function parseList(html) { const $ = load(html), values = new Map(); for (const node of $('.public-list-box').toArray()) {
    const card = $(node), link = card.find('a[href*="/voddetail/"]').first(), href = link.attr('href') ?? '', id = /\/voddetail\/(\d+)\.html/u.exec(href)?.[1], title = clean(link.attr('title') ?? card.find('.time-title').text()).replace(/封面图$/u, '');
    if (!id || !title)
        continue;
    const image = card.find('img').first(), cover = absolute(image.attr('data-src') ?? image.attr('data-original') ?? image.attr('src') ?? ''), remark = clean(card.find('.public-list-prb').first().text());
    values.set(id, { id, title, cover, remark, category: '' });
} return [...values.values()]; }
function parseEpisodes(html) { const $ = load(html), values = new Map(), labels = $('.anthology-tab .swiper-slide').toArray().map(node => clean($(node).text()).replace(/\s*\d+\s*$/u, '')); for (const [boxIndex, node] of $('.anthology-list-box').toArray().entries()) {
    const group = labels[boxIndex] || `线路${boxIndex + 1}`;
    for (const link of $(node).find('a[href*="/vodplay/"]').toArray()) {
        const anchor = $(link), href = anchor.attr('href') ?? '', match = /\/vodplay\/\d+-(\d+)-(\d+)\.html/u.exec(href), title = clean(anchor.text());
        if (!match || !title)
            continue;
        const line = match[1] ?? '', number = match[2] ?? '';
        values.set(`${line}:${number}`, { line, number, title, group });
    }
} return [...values.values()]; }
function extractObject(html, name) { const marker = new RegExp(`var\\s+${name}\\s*=\\s*`, 'u').exec(html); if (!marker)
    return ''; const start = html.indexOf('{', marker.index + marker[0].length); if (start < 0)
    return ''; let depth = 0, string = false, quote = '', escaped = false; for (let index = start; index < html.length; index += 1) {
    const char = html[index] ?? '';
    if (string) {
        if (escaped)
            escaped = false;
        else if (char === '\\')
            escaped = true;
        else if (char === quote)
            string = false;
    }
    else if (char === '"' || char === "'") {
        string = true;
        quote = char;
    }
    else if (char === '{')
        depth += 1;
    else if (char === '}' && --depth === 0)
        return html.slice(start, index + 1);
} return ''; }
function summary(value) { if (!/^\d+$/u.test(value.id) || !value.title)
    return null; return frozen({ id: `video:${value.id}`, title: value.title, contentKind: 'video', coverOrientation: 'portrait', author: null, url: `${base}/voddetail/${value.id}.html`, coverUrl: proxyImage(value.cover), description: null, language: 'zh-CN', status: 'unknown', access: 'free', wordCount: null, chapterCount: null, publishedAt: null, updatedAt: null, latestChapter: value.remark ? { id: `video:${value.id}:latest`, title: value.remark, url: null, updatedAt: null } : null, categories: value.category ? [value.category] : [], tags: [], attributes: [] }); }
function proxyImage(url) { return safeUrl(url) ? requireContext().resource.proxy({ kind: 'image', url, headers: { Referer: `${base}/` } }) : null; }
function absolute(value) { if (value.startsWith('//'))
    return `https:${value}`; try {
    return new URL(value, base).toString();
}
catch {
    return '';
} }
function contentId(id) { const value = /^video:(\d+)$/u.exec(id)?.[1]; if (!value)
    throw new Error('Content ID is invalid.'); return value; }
function episodeId(id, value) { return `video:${id}:${value.line}:${value.number}`; }
function chapterKey(id, content) { const match = new RegExp(`^video:${content}:(\\d+):(\\d+)$`, 'u').exec(id); if (!match)
    throw new Error('Chapter ID is invalid.'); return { line: match[1] ?? '', number: match[2] ?? '' }; }
function safeUrl(value) { try {
    return ['http:', 'https:'].includes(new URL(value).protocol);
}
catch {
    return false;
} }
function isObject(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function text(value) { return typeof value === 'string' ? value.trim() : typeof value === 'number' ? String(value) : ''; }
function clean(value) { return value.replaceAll(/<[^>]+>/gu, ' ').replaceAll(/\s+/gu, ' ').trim(); }
function notNull(value) { return value !== null; }
function clamp(value) { return Math.max(1, Math.min(50, Math.floor(value))); }
function frozen(value) { return Object.freeze(value); }
function requireContext() { if (!context)
    throw new Error('Source is not activated.'); return context; }
