/**
 * Bilibili audiobook search and audio playback source.
 *
 * Responsibilities: query Bilibili's public web APIs and project videos into
 * stable audio summaries, multipart catalogs, and on-demand proxied playback.
 * Lifecycle: Runtime injects the public context through activate; no account
 * cookies or login session are read or stored.
 * IO: Search/view/playurl JSON and short links use ctx.http; media uses Runtime proxy.
 * Discovery declares an inline input; URLs resolve through search to normal details.
 * View requests share a bounded one-minute cache, cleared on activation and failure.
 * IDs: audio items use BV identifiers and track IDs use stable CIDs.
 */
import type { MgReadPluginContext } from '@mgread/source-api';

type Context = MgReadPluginContext;
type Json = Record<string, unknown>;

const api = 'https://api.bilibili.com';
const site = 'https://www.bilibili.com';
const userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/136.0.0.0 Safari/537.36';
const requestHeaders = Object.freeze({ Accept: 'application/json, text/plain, */*', 'Accept-Language': 'zh-CN,zh;q=0.9', Referer: `${site}/`, 'User-Agent': userAgent });
let context: Context | undefined;
const views = new Map<string, { expires: number; value: Promise<Json> }>();

export async function activate(next: Context): Promise<void> {
  context = next;
  views.clear();
  next.log.info('source_activated');
}

export async function discover(request: { target: string | null; cursor: string | null; collectionId: string | null }) {
  if (request.target !== null || request.cursor !== null || request.collectionId !== null) throw new Error('Discovery is not supported.');
  return frozen({ kind: 'document' as const, document: { components: [{
    type: 'section', id: 'audio-links', title: 'B站链接听书',
    subtitle: '粘贴视频链接、分享文本或 BV 号，读取后选择分 P 播放音频。', icon: 'audio',
    children: [{ type: 'searchInput', id: 'video-link', label: 'B站视频链接或 BV 号',
      placeholder: 'https://www.bilibili.com/video/BV… 或 b23.tv 短链接', submitLabel: '读取音频' }],
  }] } });
}

export async function search(request: { query: string; cursor: string | null; pageSize: number }) {
  const query = request.query.trim();
  if (query === '') return frozen({ items: [], nextCursor: null, totalCount: 0 });
  const bvid = await inputBvid(query);
  if (bvid !== null) {
    const detail = await getDetail({ id: `bvid:${bvid}` });
    return frozen({ items: [detail], nextCursor: null, totalCount: 1 });
  }
  const page = cursorPage(request.cursor);
  const limit = clamp(request.pageSize);
  const json = await fetchJson(`${api}/x/web-interface/search/type?${new URLSearchParams({ search_type: 'video', keyword: query, page: String(page) })}`);
  const data = asObject(json.data);
  const results = Array.isArray(data.result) ? data.result : [];
  const items = results.filter(isObject).map((entry) => {
    const bvid = validBvid(text(entry.bvid));
    if (bvid === null) return null;
    return summary({
      bvid,
      title: stripHtml(text(entry.title)) || `视频 ${bvid}`,
      author: text(entry.author) || null,
      cover: text(entry.pic),
      description: stripHtml(text(entry.description)) || null,
      duration: parseDuration(text(entry.duration)),
    });
  }).filter((item): item is ReturnType<typeof summary> => item !== null).slice(0, limit);
  return frozen({ items, nextCursor: results.length >= limit ? `search:${page + 1}` : null, totalCount: numberOrNull(data.numResults) });
}

export async function searchSuggestions(_request: { cursor: string | null; pageSize: number }) {
  return frozen({ items: [], nextCursor: null });
}

export async function getDetail(request: { id: string }) {
  const bvid = contentBvid(request.id);
  const data = await view(bvid);
  const item = summary({
    bvid,
    title: text(data.title) || `视频 ${bvid}`,
    author: text(asObject(data.owner).name) || null,
    cover: text(data.pic),
    description: text(data.desc) || null,
    duration: numberOrNull(data.duration),
  });
  return frozen({ ...item, description: text(data.desc) || null, aliases: [], catalogUrl: item.url });
}

export async function getChapters(request: { id: string }) {
  const bvid = contentBvid(request.id);
  const data = await view(bvid);
  const pages = Array.isArray(data.pages) ? data.pages.filter(isObject) : [];
  const items = pages.map((page, index) => {
    const cid = text(page.cid);
    if (cid === '') return null;
    const pageNumber = numberOrNull(page.page) ?? index + 1;
    const title = text(page.part) || `P${pageNumber}`;
    return frozen({
      id: episodeId(bvid, cid), title, order: index,
      url: `${site}/video/${bvid}/?p=${pageNumber}`,
      volumeTitle: '音频选集', wordCount: null,
      updatedAt: null, isLocked: null,
      attributes: durationAttribute(page.duration),
    });
  }).filter((item): item is NonNullable<typeof item> => item !== null);
  const groups = items.length === 0 ? [] : [frozen({ id: `group:${bvid}:pages`, title: '视频选集', order: 0, episodes: items })];
  return frozen({ items, groups });
}

export async function getContent(request: { id: string; chapterId: string }) {
  const bvid = contentBvid(request.id);
  const cid = episodeCid(request.chapterId, bvid);
  const params = new URLSearchParams({ bvid, cid, qn: '80', fnval: '16', fourk: '1' });
  const data = await fetchJson(`${api}/x/player/playurl?${params}`);
  const payload = asObject(data.data);
  const dash = asObject(payload.dash);
  const tracks = (Array.isArray(dash.audio) ? dash.audio.filter(isObject) : [])
    .filter((track) => text(track.codecs).startsWith('mp4a.') && safeHttpUrl(text(track.baseUrl || track.base_url)))
    .sort((left, right) => (numberOrNull(right.bandwidth) ?? 0) - (numberOrNull(left.bandwidth) ?? 0));
  const upstream = text(tracks[0]?.baseUrl || tracks[0]?.base_url);
  if (!safeHttpUrl(upstream)) return requireContext().errors.raise({
    code: 'source_media_resolution_failed', message: 'B站未返回可播放的独立音轨。', annotation: '请确认视频公开可用后重试。',
  });
  const headers = { Referer: `${site}/video/${bvid}/`, 'User-Agent': userAgent };
  return frozen({
    chapterId: request.chapterId, contentKind: 'audio', title: null, updatedAt: null,
    text: null, pages: [],
    media: {
      url: requireContext().resource.proxy({ kind: 'audio', url: upstream, headers }),
      resourceType: 'audio', resourcePolicy: 'sessionOnly', expiresAt: null,
      mimeType: 'audio/mp4', headers,
    },
  });
}

async function view(bvid: string): Promise<Json> {
  const cached = views.get(bvid);
  if (cached !== undefined && cached.expires > Date.now()) return cached.value;
  if (views.size >= 16) views.delete(views.keys().next().value!);
  const value = fetchJson(`${api}/x/web-interface/view?bvid=${encodeURIComponent(bvid)}`).then((response) => {
    const data = asObject(response.data);
    if (text(data.bvid) !== bvid) throw new Error('B站返回的视频与输入不一致。');
    return data;
  });
  const entry = { expires: Date.now() + 60_000, value };
  views.set(bvid, entry);
  try { return await value; }
  catch (error) { if (views.get(bvid) === entry) views.delete(bvid); throw error; }
}

async function fetchJson(url: string): Promise<Json> {
  const response = await requireContext().http.fetch(url, { headers: requestHeaders });
  if (!response.ok) {
    if ([403, 412, 429].includes(response.status)) blocked(`B站请求被拒绝（HTTP ${response.status}）。`);
    throw new Error(`B站请求失败（HTTP ${response.status}）。`);
  }
  const payload: unknown = await response.json();
  const root = asObject(payload);
  if ([-352, -412].includes(Number(root.code))) blocked(`B站访问受限（${root.code}）。`);
  if (Number(root.code) !== 0) throw new Error(`B站未返回视频数据：${text(root.message) || text(root.code)}。`);
  return root;
}

function blocked(message: string): never {
  return requireContext().errors.raise({ code: 'source_access_blocked', message, annotation: '请稍后重试；这不表示数据源未安装。' });
}

async function inputBvid(input: string): Promise<string | null> {
  const direct = /(?<![A-Za-z0-9])BV[1-9A-HJ-NP-Za-km-z]{10}(?![A-Za-z0-9])/u.exec(input)?.[0];
  if (direct !== undefined) return direct;
  const short = /https?:\/\/b23\.tv\/[A-Za-z0-9]+/u.exec(input)?.[0];
  if (short !== undefined) {
    const response = await requireContext().http.fetch(short, { headers: requestHeaders });
    if ([403, 412, 429].includes(response.status)) blocked(`B站短链接请求被拒绝（HTTP ${response.status}）。`);
    const target = new URL(response.url || short);
    const match = /^\/video\/(BV[1-9A-HJ-NP-Za-km-z]{10})(?:\/|$)/u.exec(target.pathname);
    if (response.ok && (target.hostname === 'www.bilibili.com' || target.hostname === 'bilibili.com') && match?.[1]) return match[1];
    throw new Error('无法解析 B站短链接，请使用完整视频链接或 BV 号。');
  }
  if (/bilibili\.com|b23\.tv|^BV/u.test(input)) throw new Error('请输入有效的 B站视频链接或 BV 号。');
  return null;
}

function summary(value: { bvid: string; title: string; author: string | null; cover: string; description: string | null; duration: number | null }) {
  return frozen({
    id: `bvid:${value.bvid}`, title: value.title, contentKind: 'audio', coverOrientation: 'landscape',
    author: value.author, url: `${site}/video/${value.bvid}/`, coverUrl: proxyImage(value.cover),
    description: value.description, language: 'zh-CN', status: 'unknown', access: 'unknown',
    wordCount: null, chapterCount: null, publishedAt: null, updatedAt: null, latestChapter: null,
    categories: [], tags: [], attributes: durationAttribute(value.duration),
  });
}

function proxyImage(value: string): string | null {
  if (value === '') return null;
  const url = absoluteHttpUrl(value.startsWith('//') ? `https:${value}` : value);
  return url === null ? null : requireContext().resource.proxy({ kind: 'image', url, headers: { Referer: `${site}/` } });
}

function contentBvid(id: string): string {
  const match = /^bvid:(BV[1-9A-HJ-NP-Za-km-z]{10})$/u.exec(id);
  if (match?.[1] === undefined) throw new Error('Video ID is invalid.');
  return match[1];
}

function episodeId(bvid: string, cid: string): string { return `bvid:${bvid}:cid:${cid}`; }
function episodeCid(id: string, bvid: string): string {
  const match = new RegExp(`^bvid:${bvid}:cid:(\\d+)$`, 'u').exec(id);
  if (match?.[1] === undefined) throw new Error('Episode ID is invalid.');
  return match[1];
}

function validBvid(value: string): string | null {
  return /^BV[1-9A-HJ-NP-Za-km-z]{10}$/u.test(value) ? value : null;
}
function cursorPage(cursor: string | null): number {
  if (cursor === null) return 1;
  const page = Number(cursor.startsWith('search:') ? cursor.slice(7) : NaN);
  if (!Number.isSafeInteger(page) || page < 2 || page > 1000) throw new Error('Cursor is invalid.');
  return page;
}
function clamp(value: number): number { return Math.max(1, Math.min(50, Math.floor(value))); }
function durationAttribute(value: unknown) {
  const duration = numberOrNull(value);
  return duration === null ? [] : [{ key: 'durationSeconds', label: '时长（秒）', value: String(duration) }];
}
function parseDuration(value: string): number | null {
  const parts = value.split(':').map(Number);
  if (parts.some((part) => !Number.isFinite(part))) return null;
  return parts.reduce((total, part) => total * 60 + part, 0);
}
function stripHtml(value: string): string { return decodeHtml(value.replace(/<[^>]*>/gu, '').replace(/\s+/gu, ' ')).trim(); }
function decodeHtml(value: string): string {
  return value.replace(/&amp;/giu, '&').replace(/&quot;/giu, '"').replace(/&#39;/giu, "'")
    .replace(/&lt;/giu, '<').replace(/&gt;/giu, '>').replace(/&nbsp;/giu, ' ');
}
function absoluteHttpUrl(value: string): string | null { return safeHttpUrl(value) ? new URL(value).toString() : null; }
function safeHttpUrl(value: string): boolean {
  try { const url = new URL(value); return (url.protocol === 'https:' || url.protocol === 'http:') && url.username === '' && url.password === ''; }
  catch { return false; }
}
function text(value: unknown): string { return typeof value === 'string' ? value.trim() : typeof value === 'number' ? String(value) : ''; }
function numberOrNull(value: unknown): number | null { return typeof value === 'number' && Number.isFinite(value) ? value : null; }
function asObject(value: unknown): Json { return value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Json : {}; }
function isObject(value: unknown): value is Json { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function frozen<T>(value: T): T { return Object.freeze(value); }
function requireContext(): Context { if (context === undefined) throw new Error('Source is not activated.'); return context; }
