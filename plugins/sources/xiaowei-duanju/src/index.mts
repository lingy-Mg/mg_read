/**
 * 小微短剧原生数据源。
 *
 * 职责：直接调用 9ddm 短剧 API，投影检索、分类、详情、集数与清晰度资源。
 * 生命周期：activate 注入 Runtime 上下文；插件不保存账号、令牌或页面缓存。
 * IO：JSON 请求只走 ctx.http；封面和最终媒体地址只经 ctx.resource.proxy 暴露。
 * 稳定标识：内容使用 oneId，章节使用接口 playOrder/id，不把 URL 或数组下标当 ID。
 */
import type { MgReadPluginContext } from '@mgread/source-api';

type Json = Record<string, unknown>;
type Context = MgReadPluginContext;

const base = 'https://api.drama.9ddm.com/drama/home';
const clientInfo = '0123456789abcdef0123456789abcdef';
const requestHeaders = Object.freeze({ 'Content-Type': 'application/json; charset=utf-8', 'User-Agent': 'okhttp/5.1.0' });
let context: Context | undefined;

export async function activate(next: Context): Promise<void> { context = next; next.log.info('source_activated'); }

export async function search(request: { query: string; cursor: string | null; pageSize: number }) {
  const query = request.query.trim(); if (query === '') return frozen({ items: [], nextCursor: null, totalCount: 0 });
  const page = pageCursor(request.cursor, 'search');
  const json = await fetchJson('/search', { audience: '', order: '', page, pageSize: clamp(request.pageSize), searchWord: query, subject: '' });
  const values = pickList(json).filter((item) => matches(item, query)).slice(0, clamp(request.pageSize));
  return frozen({ items: values.map(summaryFrom), nextCursor: values.length >= clamp(request.pageSize) ? `search:${page + 1}` : null, totalCount: null });
}

export async function searchSuggestions(_request: { cursor: string | null; pageSize: number }) { return frozen({ items: [], nextCursor: null }); }

export async function discover(request: { target: string | null; cursor: string | null; collectionId: string | null; pageSize: number }) {
  if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null) throw new Error('Initial discovery request is invalid.');
    const tagJson = await fetchJson('/shortVideoTags'); const tags = unique(object(tagJson.data).tags ?? tagJson.tags);
    return frozen({ kind: 'document' as const, document: { components: [{ type: 'section', id: 'drama-tags', title: '短剧分类', subtitle: '按题材浏览', icon: 'video', children: [{ type: 'categoryCollection', id: 'drama-tags-list', layout: 'chips', categories: tags.map((title) => ({ id: encodeKey(title), title, target: `tag:${encodeKey(title)}`, count: null, url: null, icon: 'video' })) }] }] } });
  }
  const encoded = /^tag:(.+)$/u.exec(request.target)?.[1]; if (encoded === undefined) throw new Error('Discovery target is invalid.');
  const subject = decodeKey(encoded); const page = pageCursor(request.cursor, request.target); const limit = clamp(request.pageSize);
  const json = await fetchJson('/search', { audience: '全部', order: '最新', page, pageSize: limit, searchWord: '', subject });
  const values = pickList(json).slice(0, limit); const collectionId = `drama:${encoded}`;
  const items = values.map((item) => frozen({ content: summaryFrom(item), rank: null, metric: null, recommendation: null }));
  const continuation = values.length >= limit ? frozen({ target: request.target, cursor: `${request.target}:${page + 1}` }) : null;
  if (request.collectionId !== null) { if (request.collectionId !== collectionId) throw new Error('Discovery collection is invalid.'); return frozen({ kind: 'append' as const, collectionId, items, continuation }); }
  return frozen({ kind: 'document' as const, document: { components: [{ type: 'section', id: `${collectionId}:section`, title: subject, subtitle: null, icon: 'video', children: [{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation }] }] } });
}

export async function getDetail(request: { id: string }) {
  const id = contentId(request.id); const json = await detailJson(id); const episodes = detailEpisodes(json); const first = episodes[0] ?? {};
  const item = summaryFrom({ ...first, ...json, oneId: id });
  return frozen({ ...item, description: text(json.description) || text(first.description) || null, aliases: [], catalogUrl: detailUrl(id) });
}

export async function getChapters(request: { id: string }) {
  const id = contentId(request.id); const episodes = detailEpisodes(await detailJson(id));
  const items = episodes.map((episode, index) => chapter(id, episode, index));
  if (items.length === 0) throw new Error('No playable episodes found.');
  const group = frozen({ id: `group:${encodeKey(id)}:default`, title: '默认线路', order: 0, episodes: items });
  return frozen({ items, groups: [group] });
}

export async function getContent(request: { id: string; chapterId: string }) {
  const id = contentId(request.id); const key = chapterKey(request.chapterId, id); const episodes = detailEpisodes(await detailJson(id));
  const selectedIndex = episodes.findIndex((episode, index) => episodeKey(episode, index) === key); if (selectedIndex < 0) throw new Error('Chapter ID is invalid.');
  const episode = episodes[selectedIndex] ?? {}; const choices = records(episode.videoClarityList); const best = pickBest(choices); const upstream = text(best.url);
  if (!safeUrl(upstream)) throw new Error('Playback address is unavailable.');
  const resourceType = /\.m3u8(?:$|[?#])/iu.test(upstream) ? 'hls' : 'video'; const mediaHeaders = { 'User-Agent': requestHeaders['User-Agent'] };
  return frozen({ chapterId: request.chapterId, contentKind: 'video', title: `第${text(episode.playOrder) || selectedIndex + 1}集`, updatedAt: null, text: null, pages: [], media: { url: requireContext().resource.proxy({ kind: resourceType, url: upstream, headers: mediaHeaders }), resourceType, resourcePolicy: 'sessionOnly', expiresAt: null, mimeType: resourceType === 'hls' ? 'application/vnd.apple.mpegurl' : 'video/mp4', headers: mediaHeaders } });
}

async function detailJson(id: string) { return fetchJson(`/shortVideoDetail?oneId=${encodeURIComponent(id)}&page=1&pageSize=500&userId=0&queryAll=true`); }
async function fetchJson(path: string, body?: Json): Promise<Json> {
  const url = `${base}${path}${path.includes('?') ? '&' : '?'}${commonQuery()}`;
  const init = body === undefined ? { method: 'GET', headers: requestHeaders } : { method: 'POST', headers: requestHeaders, body: JSON.stringify(body) };
  const response = await requireContext().http.fetch(url, init);
  if (!response.ok) throw new Error('Source request failed.'); const value: unknown = await response.json(); if (!isObject(value)) throw new Error('Source response is invalid.'); return value;
}
function commonQuery() { return `version_code=1500&version_name=1.5.0&device_name=${encodeURIComponent('Pixel 8 Pro')}&device_type=phone&is_first_day=true&is_first_24h=true&app_launch_way=icon&default_homepage=homepage_interaction&device_owning_firm=Google&font_scale=default&os_type=1&clientInfo=${clientInfo}`; }
function detailUrl(id: string) { return `${base}/shortVideoDetail?oneId=${encodeURIComponent(id)}`; }
function detailEpisodes(json: Json) { const direct = records(json.data); return direct.length > 0 ? direct : records(object(json.data).list); }
function pickList(json: Json) { const direct = records(json.data); if (direct.length > 0) return direct; const nested = records(object(json.data).list); return nested.length > 0 ? nested : records(json.list); }
function summaryFrom(item: Json) {
  const native = text(item.oneId) || text(item.id); if (native === '') throw new Error('Source item has no ID.'); const id = encodeKey(native); const total = integer(item.episodeCount ?? item.totalEpisodeCount ?? item.totalEpisode);
  return frozen({ id: `drama:${id}`, title: text(item.title) || text(item.name) || native, contentKind: 'video', coverOrientation: text(item.horzPoster) !== '' ? 'landscape' : 'portrait', author: null, url: detailUrl(native), coverUrl: proxyImage(first(item.horzPoster, item.vertPoster, item.cover)), description: nullable(item.description), language: 'zh-CN', status: 'unknown', access: 'unknown', wordCount: null, chapterCount: total, publishedAt: null, updatedAt: null, latestChapter: null, categories: [], tags: [], attributes: [] });
}
function chapter(id: string, episode: Json, index: number) { const key = episodeKey(episode, index); const order = integer(episode.playOrder ?? episode.episode) ?? index + 1; return frozen({ id: `drama:${encodeKey(id)}:${encodeKey(key)}`, title: `第${order}集`, order: Math.max(0, order - 1), url: null, volumeTitle: '默认线路', wordCount: null, updatedAt: null, isLocked: null, attributes: [] }); }
function episodeKey(episode: Json, index: number) { const key = text(episode.id) || text(episode.videoId) || text(episode.playOrder) || text(episode.episode); if (key === '') throw new Error(`Episode ${index + 1} has no stable ID.`); return key; }
function contentId(id: string) { const encoded = /^drama:([^:]+)$/u.exec(id)?.[1]; if (encoded === undefined) throw new Error('Content ID is invalid.'); return decodeKey(encoded); }
function chapterKey(id: string, content: string) { const prefix = `drama:${encodeKey(content)}:`; if (!id.startsWith(prefix)) throw new Error('Chapter ID is invalid.'); return decodeKey(id.slice(prefix.length)); }
function pickBest(list: Json[]) { return list.find((item) => /1080/iu.test(text(item.name))) ?? list[0] ?? {}; }
function matches(item: Json, query: string) { const value = `${text(item.title)} ${text(item.name)} ${text(item.bookName)}`.toLocaleLowerCase('zh-CN'); return value.includes(query.toLocaleLowerCase('zh-CN')); }
function pageCursor(cursor: string | null, scope: string) { if (cursor === null) return 1; const value = Number(new RegExp(`^${escape(scope)}:(\\d+)$`, 'u').exec(cursor)?.[1]); if (!Number.isSafeInteger(value) || value < 2 || value > 1000) throw new Error('Cursor is invalid.'); return value; }
function safeUrl(value: string) { try { const url = new URL(value); return (url.protocol === 'https:' || url.protocol === 'http:') && url.username === '' && url.password === ''; } catch { return false; } }
function proxyImage(value: unknown) { const url = text(value); return safeUrl(url) ? requireContext().resource.proxy({ kind: 'image', url, headers: { 'User-Agent': requestHeaders['User-Agent'] } }) : null; }
function encodeKey(value: string) { return Buffer.from(value, 'utf8').toString('base64url'); }
function decodeKey(value: string) { if (!/^[A-Za-z0-9_-]+$/u.test(value)) throw new Error('Source key is invalid.'); return Buffer.from(value, 'base64url').toString('utf8'); }
function unique(value: unknown) { return [...new Set(strings(value).map((item) => item.trim()).filter(Boolean))]; }
function strings(value: unknown) { return Array.isArray(value) ? value.filter((item): item is string => typeof item === 'string') : []; }
function records(value: unknown): Json[] { return Array.isArray(value) ? value.filter(isObject) : []; }
function object(value: unknown): Json { return isObject(value) ? value : {}; }
function isObject(value: unknown): value is Json { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function text(value: unknown) { return typeof value === 'string' ? value.trim() : typeof value === 'number' ? String(value) : ''; }
function nullable(value: unknown) { const valueText = text(value); return valueText === '' ? null : valueText; }
function integer(value: unknown) { const result = Number(value); return Number.isSafeInteger(result) && result >= 0 ? result : null; }
function first(...values: unknown[]) { return values.find((value) => value !== null && value !== undefined && value !== '') ?? ''; }
function clamp(value: number) { return Math.max(1, Math.min(50, Math.floor(value))); }
function escape(value: string) { return value.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&'); }
function frozen<T>(value: T): T { return Object.freeze(value); }
function requireContext(): Context { if (context === undefined) throw new Error('Source is not activated.'); return context; }
