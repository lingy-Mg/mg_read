/**
 * WNACG 图集：公开推荐、搜索、详情与完整下拉页图；所有 IO 经公开 Context。
 * activate 清理有界详情和推荐快照；图集 aid 同时作为单一图集章节身份，页身份只取图片路径。
 * 下拉脚本仅解析已声明图片 URL，不执行 eval 或旧规则；每次 getContent 重取站点签名，签名不进入 ID。
 * 核对详情页数与唯一图片数；不把广告图片当作品页，不截断、不合成缺页，不持久化图片或正文。
 */
import { createHash } from 'node:crypto';
import { load } from 'cheerio';
import type { MgReadPluginContext } from '@mgread/source-api';

const SITE = 'https://www.wnacg.com';
let context: MgReadPluginContext | undefined;
const details = new Map<string, { at: number; value: ReturnType<typeof parseDetail> }>();
const snapshots = new Map<string, { at: number; ids: string[] }>();
export async function activate(next: MgReadPluginContext) { context = next; details.clear(); snapshots.clear(); next.log.info('wnacg_source_activated'); }
export async function search(request: { query: string; cursor: string | null; pageSize: number }) {
  const query = request.query.trim(); if (!query) return { items: [], nextCursor: null, totalCount: 0 };
  const scope = `search:${digest(query)}`, position = searchPosition(request.cursor, scope), url = new URL('/search/', SITE);
  url.search = new URLSearchParams({ q: query, f: '_all', s: 'create_time_DESC', syn: 'yes', p: String(position.page) }).toString();
  const $ = load(await getHtml(url)), ids = listingIds($), slice = slicePage(ids, position.offset, request.pageSize);
  const next = $('a[href]').toArray().filter(n => /^(?:下一頁|下頁|下一页|下页)$/u.test(clean($(n).text())));
  const nextUrls = [...new Set(next.map(n => siteUrl($(n).attr('href') ?? '', url)?.href ?? ''))];
  const target = nextUrls[0] ? new URL(nextUrls[0]) : null;
  if (nextUrls.length > 1 || (nextUrls.length && !target) || (target && (target.pathname.replace(/\/$/u, '') !== '/search' || Number(target.searchParams.get('p')) !== position.page + 1 || target.searchParams.get('q') !== query))) throw new Error('Search next-page link changed.');
  return { items: await summaries(slice.ids), nextCursor: slice.end < ids.length ? `${scope}:${position.page}:${slice.end}` : target ? `${scope}:${position.page + 1}:0` : null, totalCount: null };
}
export async function searchSuggestions(_request: { cursor: string | null; pageSize: number }) { return { items: [], nextCursor: null }; }
export async function discover(request: { target: string | null; cursor: string | null; collectionId: string | null; pageSize: number }) {
  if (request.target !== null && !/^featured:[a-f0-9]{12}$/u.test(request.target)) throw new Error('Invalid discovery target.');
  if (request.target === null && (request.cursor !== null || request.collectionId !== null)) throw new Error('Invalid initial discovery request.');
  if (request.collectionId !== null && request.collectionId !== 'wnacg:featured') throw new Error('Invalid discovery collection.');
  let target = request.target, ids: string[];
  if (target === null) {
    ids = listingIds(load(await getHtml(new URL('/', SITE)))); if (!ids.length) throw new Error('Recommendations are missing.');
    target = `featured:${digest(ids.join(','))}`;
    if (snapshots.size >= 4) snapshots.delete(snapshots.keys().next().value!); snapshots.set(target, { at: Date.now(), ids });
  } else { const hit = snapshots.get(target); if (!hit || Date.now() - hit.at > 300000) throw new Error('Featured list has expired; refresh discovery.'); ids = hit.ids; }
  const slice = slicePage(ids, featuredOffset(request.cursor, target), request.pageSize);
  const items = (await summaries(slice.ids)).map(content => ({ content, rank: null, metric: null, recommendation: null }));
  const continuation = slice.end < ids.length ? { target, cursor: `${target}:${slice.end}` } : null;
  if (request.collectionId !== null) return { kind: 'append' as const, collectionId: 'wnacg:featured', items, continuation };
  return { kind: 'document' as const, document: { components: [{ type: 'section', id: 'wnacg-featured-section', title: '图集推荐', subtitle: null, icon: 'manga',
    children: [{ type: 'contentCollection', id: 'wnacg:featured', layout: 'coverGrid', items, continuation }] }] } };
}
export async function getDetail(request: { id: string }) {
  const data = await detail(albumId(request.id)); return { ...summary(data), description: null, aliases: [], catalogUrl: `${SITE}/photos-index-aid-${data.id}.html` };
}
export async function getChapters(request: { id: string; refresh?: boolean }) {
  const data = await detail(albumId(request.id), request.refresh === true);
  return { items: [{ id: `gallery:${data.id}`, title: data.title, order: 0, url: `${SITE}/photos-gallery-aid-${data.id}.html`,
    volumeTitle: null, wordCount: null, updatedAt: null, isLocked: null, attributes: [] }], groups: [] };
}
export async function getContent(request: { id: string; chapterId: string }) {
  const id = albumId(request.id); if (request.chapterId !== `gallery:${id}`) throw new Error('Chapter identity does not match its album.');
  const data = await detail(id, true), $ = load(await getHtml(new URL(`/photos-gallery-aid-${id}.html`, SITE)));
  const scripts = $('script').toArray().map(n => $(n).text()).filter(text => /\bimglist\s*=/u.test(text));
  if (scripts.length !== 1) throw new Error('Gallery image data is missing or ambiguous.');
  const raw = scripts[0]!, matches = [...raw.matchAll(/\/\/img[1-9]\.qy0\.ru\/[^\\\s"'<>]+/gu)].map(m => m[0].replace(/&amp;/gu, '&'));
  const urls = matches.map(value => imageUrl(`https:${value}`, false));
  if (urls.some(url => !url) || new Set(urls.map(url => url!.pathname)).size !== urls.length || urls.length !== data.pageCount) throw new Error('Gallery pages are incomplete, duplicated or inconsistent with the declared page count.');
  if (!urls.length || urls.length > 2000) throw new Error('Gallery is empty or exceeds the bounded page limit.');
  const pages = urls.map((url, index) => ({ id: `page:${id}:${digest(url!.pathname)}`, index,
    url: ctx().resource.proxy({ kind: 'image', url: url!.href, headers: imageHeaders() }), mimeType: null, width: null, height: null }));
  return { chapterId: request.chapterId, contentKind: 'manga', title: data.title, updatedAt: null, text: null, pages, media: null };
}
async function detail(id: string, refresh = false) {
  const hit = details.get(id); if (!refresh && hit && Date.now() - hit.at < 120000) return hit.value;
  const value = parseDetail(load(await getHtml(new URL(`/photos-index-aid-${id}.html`, SITE))), id);
  if (details.size >= 64) details.delete(details.keys().next().value!); details.set(id, { at: Date.now(), value }); return value;
}
function parseDetail($: ReturnType<typeof load>, id: string) {
  const title = clean($('.asTBcell.uwthumb img').first().attr('alt') ?? ''); if (!title) throw new Error('Album title is missing.');
  const labels = $('.asTBcell.uwconn label').toArray().map(n => clean($(n).text()));
  const countText = labels.find(text => /^頁數[：:]/u.test(text)), count = Number(countText?.match(/\d+/u)?.[0]);
  if (!Number.isSafeInteger(count) || count < 1) throw new Error('Declared album page count is missing.');
  return { id, title, pageCount: count, cover: $('.asTBcell.uwthumb img').first().attr('src') ?? '', category: labels.find(text => /^分類[：:]/u.test(text))?.replace(/^分類[：:]\s*/u, '') || null };
}
function summary(data: Awaited<ReturnType<typeof detail>>) {
  const cover = imageUrl(data.cover, true);
  return { id: `manga:${data.id}`, title: data.title, contentKind: 'manga', coverOrientation: 'portrait', author: null,
    url: `${SITE}/photos-index-aid-${data.id}.html`, coverUrl: cover ? ctx().resource.proxy({ kind: 'image', url: cover.href, headers: imageHeaders() }) : null,
    description: null, language: null, status: 'unknown', access: 'unknown', wordCount: null, chapterCount: 1, publishedAt: null, updatedAt: null, latestChapter: null,
    categories: data.category ? [data.category] : [], tags: [], attributes: [{ key: 'pageCount', label: '页数', value: String(data.pageCount) }] };
}
async function summaries(ids: string[]) { const items: ReturnType<typeof summary>[] = [];
  for (let i = 0; i < ids.length; i += 4) items.push(...await Promise.all(ids.slice(i, i + 4).map(async id => summary(await detail(id))))); return items; }
function listingIds($: ReturnType<typeof load>) { const ids = new Set<string>(); $('.pic_box a[href]').each((_, node) => {
  const url = siteUrl($(node).attr('href') ?? '', SITE), id = url?.pathname.match(/^\/photos-index-aid-([1-9]\d*)\.html$/u)?.[1]; if (id) ids.add(id); }); return [...ids]; }
function imageUrl(raw: string, thumbnail: boolean) {
  if (!raw) return null; try { const value = raw.replace(/^\/{2,}/u, '//'), u = new URL(value, SITE);
    if (u.protocol !== 'https:' || u.username || u.password || u.port || u.hash || !(thumbnail ? /^t[1-9]\.qy0\.ru$/u : /^img[1-9]\.qy0\.ru$/u).test(u.hostname)) return null;
    const pattern = thumbnail ? /^\/data\/t\/\d+\/\d+\/[A-Za-z0-9_.-]+\.(?:jpe?g|png|gif|webp)$/iu : /^\/data\/\d+\/\d+\/[A-Za-z0-9_.-]+\.(?:jpe?g|png|gif|webp)$/iu;
    return pattern.test(u.pathname) ? u : null; } catch { return null; }
}
function imageHeaders() { return { Accept: 'image/*', Referer: `${SITE}/`, 'User-Agent': sourceAgent() }; }
async function getHtml(url: URL) {
  if (url.origin !== SITE) throw new Error('Source URL is outside its origin.');
  const r = await ctx().http.fetch(url, { headers: { Accept: 'text/html', Referer: `${SITE}/`, 'User-Agent': sourceAgent(), 'Cache-Control': 'no-cache' }, signal: AbortSignal.timeout(15000) });
  if (!r.ok || (r.url && !siteUrl(r.url, SITE))) ctx().errors.raise({ code: 'source_access_blocked', message: `来源页面暂不可用（HTTP ${r.status}）。` });
  const text = await r.text(); if (Buffer.byteLength(text) > 2 * 1024 * 1024) throw new Error('Source page exceeds the bounded size.');
  if (/<title[^>]*>[^<]*(?:Just a moment|安全验证|Access denied)/iu.test(text)) ctx().errors.raise('source_access_blocked'); return text;
}
function sourceAgent() { return `MgRead-Source/${ctx().plugin.version} (${ctx().plugin.id})`; }
function siteUrl(value: string, base: URL | string) { try { const u = new URL(value, base); return u.origin === SITE && !u.username && !u.password ? u : null; } catch { return null; } }
function slicePage(ids: string[], offset: number, size: number) { if (offset > ids.length) throw new Error('Cursor offset exceeds its source page.');
  const selected = ids.slice(offset, offset + Math.max(1, Math.min(50, Math.floor(size)))); return { ids: selected, end: offset + selected.length }; }
function searchPosition(cursor: string | null, scope: string) { if (cursor === null) return { page: 1, offset: 0 }; if (!cursor.startsWith(`${scope}:`)) throw new Error('Cursor belongs to another scope.');
  const m = /^(\d+):(\d+)$/u.exec(cursor.slice(scope.length + 1)), page = Number(m?.[1]), offset = Number(m?.[2]);
  if (!Number.isSafeInteger(page) || page < 1 || page > 1000 || !Number.isSafeInteger(offset) || offset < 0 || offset > 1000) throw new Error('Invalid cursor.'); return { page, offset }; }
function featuredOffset(cursor: string | null, scope: string) { if (cursor === null) return 0; if (!cursor.startsWith(`${scope}:`)) throw new Error('Cursor belongs to another scope.');
  const raw = cursor.slice(scope.length + 1), n = Number(raw); if (!/^\d+$/u.test(raw) || !Number.isSafeInteger(n) || n < 0 || n > 5000) throw new Error('Invalid cursor.'); return n; }
function albumId(value: string) { const m = /^manga:([1-9]\d{0,11})$/u.exec(value); if (!m) throw new Error('Invalid album ID.'); return m[1]!; }
function digest(value: string) { return createHash('sha256').update(value).digest('hex').slice(0, 12); }
function clean(value: string) { return value.replace(/[\s\u3000\u00a0]+/gu, ' ').trim(); }
function ctx(): MgReadPluginContext { if (!context) throw new Error('Source is not activated.'); return context; }
