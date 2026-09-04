/**
 * 小黄书 xChina 原生套图数据源。
 *
 * 职责：直接解析 xChina 的列表、搜索、详情及跨页图片，不执行旧数据源脚本。
 * 生命周期：activate 只保存 Runtime 上下文；章节读取最多访问 30 个站内分页。
 * IO：网页走 ctx.http，封面和原图统一经 ctx.resource.proxy。
 * 稳定标识：作品使用站内 photo 路径，章节固定为该套图的完整图集。
 */
import { load } from 'cheerio';
const base = 'https://xchina001.online', headers = { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/126.0.0.0 Safari/537.36', Accept: 'text/html,application/xhtml+xml,*/*;q=0.8', Referer: `${base}/photos.html` }, channels = [['latest', '最新', '/photos/'], ['hot', '热门', '/photos/sort-hot/'], ['comment', '评论最多', '/photos/sort-comment/'], ['recent', '最近评论', '/photos/sort-recent/']];
let context;
export async function activate(next) { context = next; next.log.info('source_activated'); }
export async function search(request) { const query = clean(request.query).replaceAll(/[\\*"?&<>]/gu, '').replaceAll(/\s+/gu, '+'); if (query.length < 2)
    return frozen({ items: [], nextCursor: null, totalCount: 0 }); const page = cursorPage(request.cursor, 'search'), path = page === 1 ? `/photos/keyword-${encodeURIComponent(query)}.html` : `/photos/keyword-${encodeURIComponent(query)}/${page}.html`, values = parseList(await get(path)), size = clamp(request.pageSize), items = values.map(summary).slice(0, size); return frozen({ items, nextCursor: values.length >= size ? `search:${page + 1}` : null, totalCount: null }); }
export async function searchSuggestions(_request) { return frozen({ items: [], nextCursor: null }); }
export async function discover(request) { if (request.target === null)
    return frozen({ kind: 'document', document: { components: [{ type: 'section', id: 'xchina-channels', title: '小黄书套图', subtitle: 'xChina 写真分类', icon: 'manga', children: [{ type: 'categoryCollection', id: 'xchina-channel-list', layout: 'chips', categories: channels.map(([id, title]) => ({ id, title, target: `channel:${id}`, count: null, url: null, icon: 'manga' })) }] }] } }); const channel = channels.find(([id]) => request.target === `channel:${id}`); if (!channel)
    throw new Error('Discovery target is invalid.'); const page = cursorPage(request.cursor, request.target), values = parseList(await get(`${channel[2]}${page}.html`)), size = clamp(request.pageSize), contents = values.map(summary).slice(0, size), collectionId = `xchina:${channel[0]}`, items = contents.map(content => frozen({ content, rank: null, metric: null, recommendation: null })), continuation = values.length >= size ? frozen({ target: request.target, cursor: `${request.target}:${page + 1}` }) : null; if (request.collectionId !== null) {
    if (request.collectionId !== collectionId)
        throw new Error('Discovery collection is invalid.');
    return frozen({ kind: 'append', collectionId, items, continuation });
} return frozen({ kind: 'document', document: { components: [{ type: 'section', id: `${collectionId}:section`, title: channel[1], subtitle: null, icon: 'manga', children: [{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation }] }] } }); }
export async function getDetail(request) { const path = contentPath(request.id), html = await get(path), $ = load(html), raw = clean($('meta[property="og:title"]').attr('content') ?? $('h1').first().text()).replace(/\s+-\s+小黄书.*$/u, ''), parts = raw.split(/\s+-\s+/u), title = parts.shift() || path, description = clean($('meta[property="og:description"]').attr('content') ?? ''), detail = clean($('.photo-detail').first().text()), remark = detail.match(/\d+\s*P(?:\s*\+\s*\d+\s*V)?/iu)?.[0] ?? '全部', date = detail.match(/\d{4}\.\d{2}\.\d{2}/u)?.[0] ?? '', item = summary({ path, title, cover: $('meta[property="og:image"]').attr('content') ?? '', author: clean($('.photo-detail .model-item').first().text()), category: clean(parts.join(' / ') || $('.photo-detail a[href^="/photos/series"]').first().text()), remark, date }); return frozen({ ...item, description: description || null, chapterCount: 1, aliases: [], catalogUrl: new URL(path, base).toString() }); }
export async function getChapters(request) { const path = contentPath(request.id), chapter = frozen({ id: `manga:${encode(path)}:main`, title: '全部', order: 0, url: null, volumeTitle: '套图', wordCount: null, updatedAt: null, isLocked: false, attributes: [] }); return frozen({ items: [chapter], groups: [frozen({ id: `group:${encode(path)}`, title: '套图', order: 0, episodes: [chapter] })] }); }
export async function getContent(request) { const path = contentPath(request.id); if (request.chapterId !== `manga:${encode(path)}:main`)
    throw new Error('Chapter ID is invalid.'); const first = await get(path), seen = new Set(), images = []; let firstImages = parseImages(first), count = Number(clean(load(first)('.photo-detail').text()).match(/(\d+)\s*P/iu)?.[1] ?? 0); if (firstImages.length && count > 1 && count <= 2000) {
    const generated = sequential(firstImages[0] ?? '', count);
    if (generated.length)
        firstImages = generated;
} for (const value of firstImages)
    if (!seen.has(value)) {
        seen.add(value);
        images.push(value);
    } if (images.length === firstImages.length && sequential(firstImages[0] ?? '', count).length === 0) {
    const max = maxPage(first);
    for (let page = 2; page <= max && page <= 30; page += 1)
        for (const value of parseImages(await get(paged(path, page))))
            if (!seen.has(value)) {
                seen.add(value);
                images.push(value);
            }
} if (!images.length)
    throw new Error('Album images are unavailable.'); const referer = new URL(path, base).toString(), pages = images.map((url, index) => frozen({ id: `page:${index + 1}`, index, url: requireContext().resource.proxy({ kind: 'image', url, headers: { ...headers, Referer: referer } }), mimeType: imageMime(url), width: null, height: null })); return frozen({ chapterId: request.chapterId, contentKind: 'manga', title: null, updatedAt: null, text: null, pages: Object.freeze(pages) }); }
async function get(path) { const url = new URL(path, base).toString(), response = await requireContext().http.fetch(url, { headers }); if (!response.ok)
    throw new Error('Source request failed.'); return response.text(); }
function parseList(html) { const $ = load(html), values = new Map(); for (const node of $('.list .item.photo').toArray()) {
    const card = $(node), link = card.find('a[href^="/photo/"]').first(), href = link.attr('href') ?? '';
    if (!href)
        continue;
    const path = new URL(href, base).pathname, title = clean(link.attr('title') ?? card.find('.title').text());
    if (!title)
        continue;
    const style = card.find('.img').attr('style') ?? '', cover = /background-image\s*:\s*url\(["']?([^"')]+)/iu.exec(style)?.[1] ?? '', subs = clean(card.find('.subs').text());
    values.set(path, { path, title, cover, author: clean(card.find('.model-item').text()), category: clean(card.find('.subs a').first().text()), remark: clean(card.find('.tags div').first().text()), date: subs.match(/\d{4}\.\d{2}\.\d{2}/u)?.[0] ?? '' });
} return [...values.values()]; }
function parseImages(html) { const $ = load(html), values = []; for (const node of $('.photo-items .item.photo-image .img').toArray()) {
    const style = $(node).attr('style') ?? '', raw = /background-image\s*:\s*url\(["']?([^"')]+)/iu.exec(style)?.[1] ?? '';
    if (raw)
        values.push(absolute(raw).replace(/\/(\d{4,5})_600x0\.webp(?:[?#].*)?$/iu, '/$1.jpg'));
} return values; }
function sequential(first, count) { const match = /^(.*\/)(\d+)(\.jpg(?:[?#].*)?)$/iu.exec(first); if (!match || count < 2 || count > 2000)
    return []; const width = (match[2] ?? '').length; return Array.from({ length: count }, (_, index) => `${match[1]}${String(index + 1).padStart(width, '0')}${match[3]}`); }
function maxPage(html) { let max = 1; for (const match of html.matchAll(/\/photo\/id-[^"']+\/(\d+)\.html/gu))
    max = Math.max(max, Number(match[1] ?? 1)); return max; }
function paged(path, page) { return path.replace(/\.html$/u, `/${page}.html`); }
function summary(value) { return frozen({ id: `manga:${encode(value.path)}`, title: value.title, contentKind: 'manga', coverOrientation: 'portrait', author: value.author || null, url: new URL(value.path, base).toString(), coverUrl: proxyImage(value.cover, value.path), description: null, language: 'zh-CN', status: 'completed', access: 'free', wordCount: null, chapterCount: 1, publishedAt: null, updatedAt: value.date || null, latestChapter: { id: `manga:${encode(value.path)}:main`, title: value.remark || '全部', url: null, updatedAt: null }, categories: value.category ? [value.category] : [], tags: ['写真', '套图'], attributes: [] }); }
function proxyImage(value, path) { if (!value)
    return null; const url = absolute(value); return requireContext().resource.proxy({ kind: 'image', url, headers: { ...headers, Referer: new URL(path, base).toString() } }); }
function absolute(value) { return new URL(value, base).toString(); }
function imageMime(url) { const path = new URL(url).pathname.toLowerCase(); return path.endsWith('.png') ? 'image/png' : path.endsWith('.webp') ? 'image/webp' : 'image/jpeg'; }
function contentPath(id) { const value = /^manga:([A-Za-z0-9_-]+)$/u.exec(id)?.[1], path = value ? decode(value) : ''; if (!/^\/photo\/id-[^/]+\.html$/u.test(path))
    throw new Error('Content ID is invalid.'); return path; }
function encode(value) { return Buffer.from(value).toString('base64url'); }
function decode(value) { return Buffer.from(value, 'base64url').toString('utf8'); }
function clean(value) { return value.replaceAll(/<[^>]+>/gu, ' ').replaceAll(/\s+/gu, ' ').trim(); }
function cursorPage(cursor, target) { if (cursor === null)
    return 1; const page = Number(cursor.startsWith(`${target}:`) ? cursor.slice(target.length + 1) : ''); if (!Number.isSafeInteger(page) || page < 2)
    throw new Error('Cursor is invalid.'); return page; }
function clamp(value) { return Math.max(1, Math.min(50, Math.floor(value))); }
function frozen(value) { return Object.freeze(value); }
function requireContext() { if (!context)
    throw new Error('Source is not activated.'); return context; }
