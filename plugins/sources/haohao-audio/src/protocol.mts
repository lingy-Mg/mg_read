/**
 * 来源私有 JSON 协议及投影工具；不持久化会话、签名地址或媒体主体。
 * activate 注入公开 Context，每次激活生成匿名会话；所有 IO 经 ctx.http，资源经 Runtime proxy。
 * 分页保留上游页内 offset，并将 cursor 绑定目标，避免 pageSize 小于上游页长时漏项。
 * 此文件随当前来源独立打包，不依赖其他来源的执行代码或 Runtime 私有实现。
 */
import { randomUUID } from 'node:crypto';
import type { MgReadPluginContext, PluginChaptersRequest } from '@mgread/source-api';

export type Json = Record<string, unknown>;
export type SearchRequest = {query: string; cursor: string | null; pageSize: number};
export type DiscoverRequest = {target: string | null; cursor: string | null; collectionId: string | null; pageSize: number};
let context: MgReadPluginContext | undefined;
let apiRoot = '', referer = '', session = '';
const snapshots = new Map<string, {expires: number; task: Promise<unknown>}>();
export function initialize(next: MgReadPluginContext, base: string, origin: string) {
  context = next; apiRoot = base; referer = origin; session = randomUUID(); snapshots.clear();
  next.log.info('source_activated');
}
/** At most 16 JSON metadata/catalog snapshots, 60s TTL; refresh invalidates, failures miss, never media. */
export async function snapshot<T>(key: string, load: () => Promise<T>, refresh = false): Promise<T> {
  const current = snapshots.get(key);
  if (!refresh && current && current.expires > Date.now()) return current.task as Promise<T>;
  const task = Promise.resolve().then(load), entry = {expires: Date.now() + 60000, task};
  snapshots.delete(key); snapshots.set(key, entry);
  while (snapshots.size > 16) snapshots.delete(snapshots.keys().next().value!);
  try { return await task; } catch (error) { if (snapshots.get(key) === entry) snapshots.delete(key); throw error; }
}
export async function remoteChapters(id: string, refresh = false) {
  return snapshot('chapters:' + id, async () => remoteCatalog(await json('chapters/' + id), id), refresh);
}
export function ctx() { if (!context) throw new Error('Source is not activated.'); return context; }
export async function json(path: string, body?: Json): Promise<Json> {
  return jsonUrl(apiRoot + path, body, {
    Origin: new URL(referer).origin, Referer: referer,
    'x-listening-timezone': 'Asia/Shanghai', 'x-listening-session': session,
  });
}
export async function jsonUrl(url: string, body?: Json, headers: Record<string, string> = {}): Promise<Json> {
  const response = await ctx().http.fetch(url, {
    method: body === undefined ? 'GET' : 'POST',
    headers: {Accept: 'application/json', ...headers, ...(body === undefined ? {} : {'Content-Type': 'application/json'})},
    ...(body === undefined ? {} : {body: JSON.stringify(body)}), signal: AbortSignal.timeout(20000),
  });
  if (!response.ok) throw new Error('Source request failed: ' + response.status);
  const value: unknown = await response.json();
  if (!object(value)) throw new Error('Source returned an invalid JSON object.');
  if (value.code !== undefined && ![0, 200].includes(Number(value.code))) throw new Error('Source API reported failure.');
  return value;
}
export const text = (value: unknown): string => typeof value === 'string' || typeof value === 'number' ? String(value).trim() : '';
export const nullable = (value: unknown) => text(value) || null;
export function object(value: unknown): value is Json { return value !== null && typeof value === 'object' && !Array.isArray(value); }
export function records(value: unknown): Json[] { return Array.isArray(value) ? value.filter(object) : []; }
export function natural(value: unknown) { if (value === null || value === undefined || value === '') return null; const n = Number(value); return Number.isSafeInteger(n) && n >= 0 ? n : null; }
export function native(value: unknown) { const id = text(value); if (!/^\d{1,20}$/u.test(id)) throw new Error('Invalid upstream ID.'); return id; }
export function album(id: string) { const m = /^album:(\d{1,20})$/u.exec(id); if (!m) throw new Error('Invalid album ID.'); return m[1]!; }
export function size(n: number) { if (!Number.isFinite(n) || n < 1) throw new Error('Invalid page size.'); return Math.min(50, Math.floor(n)); }
export function position(cursor: string | null, scope: string): {page: number; offset: number} {
  if (cursor === null) return {page: 1, offset: 0};
  let data: unknown; try { data = JSON.parse(cursor); } catch { throw new Error('Invalid cursor.'); }
  if (!Array.isArray(data) || data.length !== 3 || data[0] !== scope || !Number.isSafeInteger(data[1]) || data[1] < 1 || data[1] > 10000 || !Number.isSafeInteger(data[2]) || data[2] < 0 || data[2] > 1000) throw new Error('Invalid cursor.');
  return {page: data[1], offset: data[2]};
}
export function window<T>(values: T[], scope: string, cursor: string | null, pageSize: number, more: boolean, step = 1) {
  const {page, offset} = position(cursor, scope);
  if (offset > values.length) throw new Error('Cursor offset exceeds source page.');
  const items = values.slice(offset, offset + size(pageSize)), end = offset + items.length;
  const nextCursor = end < values.length ? JSON.stringify([scope, page, end]) : more && page + step <= 10000 ? JSON.stringify([scope, page + step, 0]) : null;
  return {items, nextCursor};
}
export function safeUrl(value: unknown, kind: 'image' | 'audio'): string | null {
  try {
    const url = new URL(text(value)), suffixes = kind === 'image' ? ['tingyou8.vip', 'xmcdn.com', 'lrts.me', 'lrts.com', '365ting.com'] : ['hgeuz.cn', '365ting.com', 'tingyou8.vip', 'xmcdn.com', 'lrts.me'];
    return ['https:', 'http:'].includes(url.protocol) && !url.username && !url.password && !url.port && suffixes.some(s => url.hostname === s || url.hostname.endsWith('.' + s)) ? url.href : null;
  } catch { return null; }
}
export function cover(value: unknown) { const url = safeUrl(value, 'image'); return url ? ctx().resource.proxy({kind: 'image', url, headers: {Referer: referer}}) : null; }
export function summary(value: Json) {
  const id = native(value.book_id ?? value.id), title = text(value.title);
  if (!title) throw new Error('Album title is missing.');
  const categories = [...new Set([text(value.cat), text(value.type)].filter(v => v && !['站内已有', '可提取', '需提取', '多人提取', '未分类'].includes(v)))];
  return {id: 'album:' + id, title, contentKind: 'audio' as const, coverOrientation: 'portrait' as const,
    author: nullable(value.author), url: apiRoot + 'album/' + id, coverUrl: cover(value.cover_url ?? value.cover),
    description: nullable(value.synopsis ?? value.description ?? value.intro ?? value.desc), language: 'zh-CN',
    status: value.status === 0 ? 'completed' as const : value.status === 1 ? 'ongoing' as const : 'unknown' as const,
    access: 'unknown' as const, wordCount: null, chapterCount: natural(value.count), publishedAt: null,
    updatedAt: timestamp(value.updated_at), latestChapter: null, categories, tags: [],
    attributes: text(value.teller) ? [{key: 'narrator', label: '演播', value: text(value.teller)}] : []};
}
export function summaries(values: Json[]) {
  const map = new Map<string, ReturnType<typeof summary>>();
  for (const value of values) { if (!/^\d{1,20}$/u.test(text(value.book_id ?? value.id)) || !text(value.title)) continue; const item = summary(value); if (!map.has(item.id)) map.set(item.id, item); }
  return [...map.values()];
}
function timestamp(value: unknown) { const n = natural(value); return n !== null && n > 0 && n < 1e11 ? new Date(n * 1000).toISOString() : null; }
export function chapters(id: string, values: Json[], provider: 'chapter' | 'track') {
  const seen = new Set<string>();
  return values.map((value, order) => {
    const chapterId = `${provider}:${id}:${native(value.id)}`;
    if (seen.has(chapterId)) throw new Error('Duplicate chapter ID.'); seen.add(chapterId);
    const title = text(value.title); if (!title) throw new Error('Chapter title is missing.');
    return {id: chapterId, title, order, url: null, volumeTitle: null, wordCount: null, updatedAt: null,
      isLocked: value.is_locked === true || value.locked === true || value.is_vip === true,
      attributes: natural(value.duration) === null ? [] : [{key: 'duration', label: '时长（秒）', value: String(value.duration)}]};
  });
}
export function remoteCatalog(data: Json, id: string) {
  if (data.available === false) ctx().errors.raise('source_access_blocked');
  if (data.id !== undefined && native(data.id) !== id) throw new Error('Catalog album ID mismatch.');
  if (!Array.isArray(data.chapters)) throw new Error('Invalid chapter catalog.');
  const values = records(data.chapters), count = natural(data.count);
  if (count !== null && count !== values.length) throw new Error('Source returned an incomplete catalog.');
  chapters(id, values, 'chapter');
  if (values.some(v => natural(v.index) === null)) throw new Error('Invalid chapter playback index.');
  return values;
}
export function catalogResult(request: PluginChaptersRequest, values: ReturnType<typeof chapters>) {
  if (values.length <= 5000) {
    const groupId = 'group:' + request.id + ':main';
    if (request.groupId !== undefined && request.groupId !== groupId) throw new Error('Requested chapter group is unavailable.');
    return {items: values, groups: values.length ? [{id: groupId, title: '节目', order: 0, episodes: values}] : []};
  }
  // Host caps one loaded catalog at 5000 items; groups are complete, stable chapter ranges.
  const groups = [];
  for (let start = 0; start < values.length; start += 1000) {
    const episodes = values.slice(start, start + 1000).map((value, order) => ({...value, order}));
    groups.push({id: 'range:' + episodes[0]!.id, title: `第 ${start + 1}-${start + episodes.length} 集`, order: groups.length, episodes});
  }
  if (groups.length > 128) throw new Error('Chapter group limit exceeded.');
  if (request.groupId !== undefined) {
    const selected = groups.find(g => g.id === request.groupId);
    if (!selected) throw new Error('Requested chapter group is unavailable.');
    return {items: selected.episodes, groups: [{...selected, order: 0}]};
  }
  if (request.supportsDeferredGroups !== true) throw new Error('Large catalog requires deferred group support.');
  return {items: groups[0]!.episodes, groups: groups.map((g, index) => index === 0 ? g : {...g, episodes: [], deferred: true})};
}
export function media(chapterId: string, upstream: unknown, title: unknown = null) {
  const url = safeUrl(upstream, 'audio'); if (!url) ctx().errors.raise('source_media_resolution_failed');
  const headers = {Referer: referer};
  return {chapterId, contentKind: 'audio' as const, title: nullable(title), updatedAt: null, text: null, pages: [],
    media: {url: ctx().resource.proxy({kind: 'audio', url, headers}), resourceType: 'audio' as const, resourcePolicy: 'sessionOnly' as const, expiresAt: null, mimeType: null, headers}};
}
