/**
 * 番薯动漫 Yoapp 原生数据源。
 *
 * 职责：实现当前 App 的动态请求校验、设备握手、响应解密、目录投影与播放地址选择。
 * 生命周期：activate 注入 Runtime 上下文；动态校验头和设备会话只保存在当前进程内。
 * IO：所有控制面请求只经 ctx.http，媒体只登记到 ctx.resource.proxy；不读取系统密钥链或旧规则配置。
 * 稳定标识：作品使用 Yoapp vod_id，章节使用线路 ID、episode_id 与 episode_index。
 */
import { createDecipheriv, createHash, createHmac, randomBytes } from 'node:crypto';
import type { MgReadPluginContext } from '@mgread/source-api';

type Context = MgReadPluginContext;
type Json = Record<string, unknown>;
type AuthState = {
  readonly deviceId: string;
  readonly signKey: string;
  readonly guards: Readonly<Record<string, string>>;
  readonly expiresAt: number;
};
type Category = readonly [id: string, title: string, action: 'category_videos' | 'weekly_rankings', typeId: string, sort: string];
type ChapterRef = { readonly source: string; readonly episodeId: string; readonly episodeIndex: string };

const hosts = Object.freeze([
  'https://yoapp-cf.fsapi.shop',
  'https://yoapp.bytegooty.com',
  'https://yoapp.fsapi.me',
  'https://yoapp-do.fsapi.shop',
]);
const apiPath = '/yoapp.php';
const token = 'yoapp_a682c34e5cc0e0c38b4f749475074db7281791ad';
const bootstrapSalt = '8124fb976064d07a5c6af58c771f1c87';
const fallbackAppSignature = '1F83BDCA0957AADDCD3CE53088D60FD228ADC463EBA105495E4EBAE6962B54D6';
const clientDeviceId = 'do3bef9a-d716-4eed-8ed3-d6de71283f36';
const userAgent = 'Dart/3.11 (dart:io)';
const playerUserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/136.0.0.0 Safari/537.36';
const preferredSources = Object.freeze(['mui6', 'BY1', 'cycp', 'new_mui1', 'new_mui2', 'mui2', 'BY2']);
const categories: readonly Category[] = Object.freeze([
  ['latest', '最新', 'category_videos', '1', 'latest'],
  ['hot', '热播', 'category_videos', '1', 'hot'],
  ['completed', '完结', 'weekly_rankings', '0', ''],
  ['ranking', '排行榜', 'weekly_rankings', '0', ''],
  ['tv', 'TV番剧', 'category_videos', '1', 'latest'],
  ['china', '国产动漫', 'category_videos', '22', 'latest'],
  ['movie', '剧场版', 'category_videos', '3', 'latest'],
  ['uhd', '4K分区', 'category_videos', '20', 'latest'],
  ['western', '欧美动漫', 'category_videos', '21', 'latest'],
]);
const searchTypes = Object.freeze(['1', '22', '3', '20', '21']);

let context: Context | undefined;
let auth: AuthState | undefined;
let authPromise: Promise<AuthState> | undefined;
const details = new Map<string, Json>();

export async function activate(next: Context): Promise<void> {
  context = next;
  auth = undefined;
  authPromise = undefined;
  details.clear();
  next.log.info('source_activated');
}

export async function search(request: { query: string; cursor: string | null; pageSize: number }) {
  const query = clean(request.query).toLocaleLowerCase('zh-CN');
  if (query === '') return frozen({ items: [], nextCursor: null, totalCount: 0 });
  const page = cursorPage(request.cursor, 'search');
  const limit = clamp(request.pageSize);
  const settled = await Promise.allSettled(searchTypes.map((typeId) => apiGet('category_videos', {
    type_id: typeId, page: String(page), page_size: String(Math.max(12, limit)), sort: 'latest',
  })));
  const rows = settled.flatMap((result) => result.status === 'fulfilled' ? indexedList(result.value) : []);
  const unique = new Map<string, ReturnType<typeof projectVideo>>();
  for (const row of rows) {
    const item = projectVideo(row);
    if (item === null || !searchable(row).includes(query)) continue;
    unique.set(item.id, item);
    if (unique.size >= limit) break;
  }
  const values = [...unique.values()].filter((value): value is NonNullable<typeof value> => value !== null);
  const hasNext = rows.length >= limit && page < 50;
  return frozen({ items: values, nextCursor: hasNext ? `search:${page + 1}` : null, totalCount: null });
}

export async function searchSuggestions(_request: { cursor: string | null; pageSize: number }) {
  return frozen({ items: [], nextCursor: null });
}

export async function discover(request: {
  target: string | null;
  cursor: string | null;
  collectionId: string | null;
  pageSize: number;
}) {
  if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null) throw new Error('Initial discovery request is invalid.');
    const latest = await listCategory(categories[0]!, 1, Math.min(12, clamp(request.pageSize)));
    const components: object[] = [];
    if (latest.length > 0) {
      components.push({
        type: 'section', id: 'fanshu-latest', title: '最新更新', subtitle: '番薯动漫当前更新', icon: 'newRelease',
        children: [{
          type: 'contentCollection', id: 'fanshu-latest-list', layout: 'coverGrid', continuation: null,
          items: latest.map((content) => frozen({ content, rank: null, metric: null, recommendation: null })),
        }],
      });
    }
    components.push({
      type: 'section', id: 'fanshu-categories', title: '动漫分类', subtitle: '按栏目继续发现', icon: 'video',
      children: [{
        type: 'categoryCollection', id: 'fanshu-category-list', layout: 'chips',
        categories: categories.map(([id, title]) => ({ id, title, target: `category:${id}`, count: null, url: null, icon: id === 'hot' || id === 'ranking' ? 'hot' : 'video' })),
      }],
    });
    return frozen({ kind: 'document' as const, document: { components } });
  }
  const category = categories.find(([id]) => request.target === `category:${id}`);
  if (category === undefined) throw new Error('Discovery target is invalid.');
  const page = cursorPage(request.cursor, request.target);
  const limit = clamp(request.pageSize);
  const values = await listCategory(category, page, limit);
  const collectionId = `fanshu:${category[0]}`;
  const items = values.map((content) => frozen({ content, rank: null, metric: null, recommendation: null }));
  const continuation = values.length >= limit && page < 50
    ? frozen({ target: request.target, cursor: `${request.target}:${page + 1}` })
    : null;
  if (request.collectionId !== null) {
    if (request.collectionId !== collectionId) throw new Error('Discovery collection is invalid.');
    return frozen({ kind: 'append' as const, collectionId, items, continuation });
  }
  return frozen({
    kind: 'document' as const,
    document: { components: [{
      type: 'section', id: `${collectionId}:section`, title: category[1], subtitle: null, icon: 'video',
      children: [{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation }],
    }] },
  });
}

export async function getDetail(request: { id: string }) {
  const id = contentId(request.id);
  const value = await detail(id);
  const item = projectVideo(value);
  if (item === null) throw new Error('Video detail is incomplete.');
  return frozen({ ...item, aliases: [], catalogUrl: item.url });
}

export async function getChapters(request: { id: string }) {
  const id = contentId(request.id);
  const value = await detail(id);
  const sources = orderedSources(array(value.play_sources ?? value.playSources).filter(isRecord));
  const groups = sources.flatMap((source, groupOrder) => {
    const sourceId = text(source.from ?? source.source ?? source.id);
    if (sourceId === '') return [];
    const title = clean(text(source.display_name ?? source.name ?? source.from)) || `线路 ${groupOrder + 1}`;
    const episodes = array(source.episodes).filter(isRecord).flatMap((episode, order) => {
      const episodeIndex = text(episode.episode_index ?? episode.index) || String(order + 1);
      const episodeId = text(episode.episode_id ?? episode.id) || episodeIndex;
      const episodeTitle = clean(text(episode.name ?? episode.title)) || `第${episodeIndex}集`;
      return [frozen({
        id: chapterId(id, sourceId, episodeId, episodeIndex), title: episodeTitle, order,
        url: `yoapp://play?vod_id=${id}&source=${encodeURIComponent(sourceId)}&episode_id=${encodeURIComponent(episodeId)}&episode_index=${encodeURIComponent(episodeIndex)}`,
        volumeTitle: title, wordCount: null, updatedAt: null, isLocked: null, attributes: [],
      })];
    });
    if (episodes.length === 0) return [];
    return [frozen({ id: `group:${id}:${encodeURIComponent(sourceId)}`, title, order: groupOrder, episodes })];
  });
  const items = groups.flatMap((group) => group.episodes).map((episode, order) => frozen({ ...episode, order }));
  if (items.length === 0) throw new Error('No playable episodes found.');
  return frozen({ items, groups });
}

export async function getContent(request: { id: string; chapterId: string }) {
  const id = contentId(request.id);
  const selected = parseChapterId(request.chapterId, id);
  const value = await detail(id);
  const sources = orderedSources(array(value.play_sources ?? value.playSources).filter(isRecord));
  const selectedSource = sources.find((source) => text(source.from ?? source.source ?? source.id) === selected.source);
  const candidates = selectedSource === undefined ? sources : [selectedSource, ...sources.filter((source) => source !== selectedSource)];
  for (const source of candidates) {
    const sourceId = text(source.from ?? source.source ?? source.id);
    const episode = matchingEpisode(source, selected);
    if (sourceId === '' || episode === null) continue;
    try {
      const play = await apiGet('video_play', {
        vod_id: id,
        source: sourceId,
        episode_index: text(episode.episode_index ?? episode.index) || selected.episodeIndex,
        episode_id: text(episode.episode_id ?? episode.id) || selected.episodeId,
      });
      const url = safeUrl(text(play.play_url ?? play.url));
      if (url === '' || incompatiblePlaylist(url)) continue;
      const resourceType = /\.m3u8(?:$|[?#])/iu.test(url) ? 'hls' as const : 'video' as const;
      const headers = playbackHeaders(play.headers);
      const proxied = requireContext().resource.proxy({ kind: resourceType, url, headers });
      return frozen({
        chapterId: request.chapterId, contentKind: 'video' as const, title: null, updatedAt: null, text: null, pages: [],
        media: {
          url: proxied, resourceType, resourcePolicy: 'sessionOnly' as const, expiresAt: null,
          mimeType: resourceType === 'hls' ? 'application/vnd.apple.mpegurl' : 'video/mp4', headers,
        },
      });
    } catch {
      continue;
    }
  }
  throw new Error('Playback address is unavailable.');
}

async function listCategory(category: Category, page: number, pageSize: number) {
  const [, , action, typeId, sort] = category;
  const params = action === 'weekly_rankings'
    ? { type_id: typeId, limit: String(pageSize) }
    : { type_id: typeId, page: String(page), page_size: String(pageSize), sort };
  return indexedList(await apiGet(action, params)).flatMap((row) => {
    const item = projectVideo(row);
    return item === null ? [] : [item];
  });
}

async function detail(id: string): Promise<Json> {
  const cached = details.get(id);
  if (cached !== undefined && array(cached.play_sources ?? cached.playSources).length > 0) return cached;
  const value = await apiGet('video_detail', { vod_id: id });
  if (clean(text(value.vod_name ?? value.name ?? value.title)) === '') throw new Error('Video detail is incomplete.');
  details.set(id, value);
  return value;
}

function projectVideo(value: Json) {
  const nativeId = text(value.vod_id ?? value.id);
  const title = clean(text(value.vod_name ?? value.name ?? value.title));
  if (!/^\d+$/u.test(nativeId) || title === '') return null;
  if (!details.has(nativeId)) details.set(nativeId, value);
  const cover = safeUrl(text(value.vod_pic ?? value.cover));
  const categoriesValue = uniqueText([value.vod_class, value.type_name, value.vod_area, value.vod_lang].map(text));
  const latest = clean(text(value.vod_remarks ?? value.latest));
  return frozen({
    id: `video:${nativeId}`, title, contentKind: 'video' as const, coverOrientation: 'portrait' as const,
    author: clean(text(value.vod_actor ?? value.vod_director)) || null,
    url: `yoapp://vod/${nativeId}`,
    coverUrl: cover === '' ? null : requireContext().resource.proxy({ kind: 'image', url: cover, headers: { Referer: `${hosts[0]}/` } }),
    description: clean(text(value.vod_blurb ?? value.vod_content ?? value.description)) || null,
    language: clean(text(value.vod_lang)) || 'zh-CN', status: 'unknown' as const, access: 'unknown' as const,
    wordCount: null, chapterCount: null, publishedAt: null, updatedAt: clean(text(value.vod_time ?? value.update_time)) || null,
    latestChapter: latest === '' ? null : { id: null, title: latest, url: null, updatedAt: null },
    categories: categoriesValue, tags: categoriesValue, attributes: [],
  });
}

async function apiGet(action: string, params: Record<string, string>): Promise<Json> {
  let active = await ensureAuth();
  try {
    return await apiGetWithKey(action, params, active.deviceId, active.signKey, active.guards);
  } catch (error) {
    if (!authError(error)) throw error;
    auth = undefined;
    authPromise = undefined;
    active = await ensureAuth();
    return apiGetWithKey(action, params, active.deviceId, active.signKey, active.guards);
  }
}

async function ensureAuth(): Promise<AuthState> {
  if (auth !== undefined && auth.expiresAt - Date.now() > 10 * 60_000) return auth;
  if (authPromise !== undefined) return authPromise;
  authPromise = loadAuth().then((value) => {
    auth = value;
    authPromise = undefined;
    return value;
  }, (error) => {
    authPromise = undefined;
    throw error;
  });
  return authPromise;
}

async function loadAuth(): Promise<AuthState> {
  const bootstrapKey = shaHex(`${token}${clientDeviceId}${bootstrapSalt}`);
  const config = await apiGetWithKey('app_config', {}, clientDeviceId, bootstrapKey, {});
  const validation = isRecord(config.request_validation) ? config.request_validation : {};
  const guards: Record<string, string> = {};
  for (const header of array(validation.headers).filter(isRecord)) {
    const name = text(header.name);
    const value = text(header.value);
    if (/^X-App-[A-Za-z0-9-]+$/u.test(name) && value !== '') guards[name] = value;
  }
  if (Object.keys(guards).length === 0) throw new Error('Yoapp request validation is unavailable.');
  const verify = isRecord(config.system_verify) ? config.system_verify : {};
  const appSignature = text(verify.app_signature_sha256) || fallbackAppSignature;
  const body = JSON.stringify({ device_id: clientDeviceId, ip: Buffer.from('124.165.51.5').toString('base64') });
  const timestamp = String(Date.now());
  const nonce = randomBytes(16).toString('hex');
  const message = ['POST', apiPath, 'device_secret', clientDeviceId, timestamp, nonce, shaHex('action=device_secret'), shaHex(body)].join('\n');
  const headers = baseHeaders({
    ...guards,
    'X-API-TOKEN': token,
    'X-Yoapp-Device-Id': clientDeviceId,
    'X-Yoapp-Timestamp': timestamp,
    'X-Yoapp-Nonce': nonce,
    'X-Yoapp-Sign': hmacBase64Url(message, bootstrapKey),
  });
  const shell = await fetchShell(new URLSearchParams({ action: 'device_secret' }), { method: 'POST', headers, body });
  const payload = decodeShell(shell);
  const deviceSecret = text(payload.device_secret ?? payload.sign_key ?? payload.secret ?? payload.key);
  if (deviceSecret === '') throw new Error('Yoapp device handshake is incomplete.');
  const rawExpiry = Number(payload.expires_at);
  const expiresAt = Number.isFinite(rawExpiry) && rawExpiry > 0
    ? (rawExpiry < 1_000_000_000_000 ? rawExpiry * 1000 : rawExpiry)
    : Date.now() + Math.max(3600, Number(payload.ttl) || 43_200) * 1000;
  return frozen({
    deviceId: clientDeviceId,
    signKey: createHmac('sha256', deviceSecret).update(appSignature.toUpperCase()).digest('hex'),
    guards: frozen(guards),
    expiresAt,
  });
}

async function apiGetWithKey(
  action: string,
  params: Record<string, string>,
  deviceId: string,
  activeSignKey: string,
  guards: Readonly<Record<string, string>>,
): Promise<Json> {
  const all: Record<string, string> = { action, token, ...params };
  const timestamp = String(Date.now());
  const nonce = randomBytes(16).toString('hex');
  const canonical = Object.keys(all).filter((key) => key !== 'token' && key !== 'sign').sort()
    .map((key) => `${encodeURIComponent(key)}=${encodeURIComponent(all[key] ?? '')}`).join('&');
  const message = ['GET', apiPath, action, deviceId, timestamp, nonce, shaHex(canonical), shaHex('')].join('\n');
  const headers = baseHeaders({
    ...guards,
    'X-Yoapp-Device-Id': deviceId,
    'X-Yoapp-Timestamp': timestamp,
    'X-Yoapp-Nonce': nonce,
    'X-Yoapp-Sign': hmacBase64Url(message, activeSignKey),
  });
  const payload = decodeShell(await fetchShell(new URLSearchParams(all), { headers }));
  if (payload.success === false) throw new Error(clean(text(payload.message)) || 'Yoapp request failed.');
  return payload;
}

async function fetchShell(query: URLSearchParams, init: RequestInit): Promise<Json> {
  let lastError: unknown;
  for (const host of hosts) {
    try {
      const response = await requireContext().http.fetch(`${host}${apiPath}?${query.toString()}`, {
        ...init,
        signal: AbortSignal.timeout(15_000),
      });
      const raw = await response.text();
      if (!response.ok) throw new Error(`${response.status} ${raw.slice(0, 180)}`);
      const parsed: unknown = JSON.parse(raw);
      if (!isRecord(parsed)) throw new Error('Yoapp response is invalid.');
      return parsed;
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError instanceof Error ? lastError : new Error('Yoapp request failed.');
}

function decodeShell(shell: Json): Json {
  if (typeof shell.data !== 'string') return shell;
  const raw = shell.data.trim();
  if (raw.startsWith('{')) {
    const parsed: unknown = JSON.parse(raw);
    if (isRecord(parsed)) return parsed;
  }
  const encryptedKey = text(shell.ek);
  if (encryptedKey === '') throw new Error('Yoapp encrypted response has no key.');
  const keyDecipher = createDecipheriv('aes-128-ecb', sha(bootstrapSalt).subarray(0, 16), null);
  const seed = Buffer.concat([keyDecipher.update(Buffer.from(encryptedKey, 'base64')), keyDecipher.final()]).toString('utf8');
  const dataDecipher = createDecipheriv('aes-256-cbc', sha(`${seed}${bootstrapSalt}`), sha(`${bootstrapSalt}${seed}`).subarray(0, 16));
  const plaintext = Buffer.concat([dataDecipher.update(Buffer.from(raw, 'base64')), dataDecipher.final()]).toString('utf8');
  const parsed: unknown = JSON.parse(plaintext);
  if (!isRecord(parsed)) throw new Error('Yoapp decrypted response is invalid.');
  return parsed;
}

function indexedList(value: Json): Json[] {
  if (Array.isArray(value.list)) return value.list.filter(isRecord);
  if (isRecord(value.data) && Array.isArray(value.data.list)) return value.data.list.filter(isRecord);
  return Object.keys(value).filter((key) => /^\d+$/u.test(key)).sort((left, right) => Number(left) - Number(right))
    .map((key) => value[key]).filter(isRecord);
}

function orderedSources(values: Json[]): Json[] {
  return [...values].sort((left, right) => sourceRank(text(left.from ?? left.source ?? left.id)) - sourceRank(text(right.from ?? right.source ?? right.id)));
}

function sourceRank(value: string): number {
  const index = preferredSources.indexOf(value);
  return index < 0 ? preferredSources.length + 1 : index;
}

function matchingEpisode(source: Json, selected: ChapterRef): Json | null {
  const episodes = array(source.episodes).filter(isRecord);
  return episodes.find((episode) => text(episode.episode_id ?? episode.id) === selected.episodeId) ??
    episodes.find((episode, index) => (text(episode.episode_index ?? episode.index) || String(index + 1)) === selected.episodeIndex) ?? null;
}

function playbackHeaders(value: unknown): Record<string, string> {
  const raw = isRecord(value) ? value : {};
  const result: Record<string, string> = {};
  const referer = text(raw.referer ?? raw.Referer);
  const agent = text(raw.user_agent ?? raw['User-Agent']);
  if (referer !== '') result.Referer = referer;
  result['User-Agent'] = agent || playerUserAgent;
  return result;
}

function incompatiblePlaylist(url: string): boolean {
  const lower = url.toLowerCase();
  return lower.includes('psch=v2') || lower.includes('pkey=') || lower.includes('playlisttype=lowlatency') ||
    (lower.includes('.m3u8') && (lower.includes('bytegooty.com/obj/') || lower.includes('lf3-cdn-tos.bytegooty.com')));
}

function contentId(id: string): string {
  const value = /^video:(\d+)$/u.exec(id)?.[1];
  if (value === undefined) throw new Error('Content ID is invalid.');
  return value;
}

function chapterId(book: string, source: string, episodeId: string, episodeIndex: string): string {
  return `video:${book}:${encodeURIComponent(source)}:${encodeURIComponent(episodeId)}:${encodeURIComponent(episodeIndex)}`;
}

function parseChapterId(id: string, book: string): ChapterRef {
  const match = new RegExp(`^video:${book}:([^:]+):([^:]+):([^:]+)$`, 'u').exec(id);
  if (match?.[1] === undefined || match[2] === undefined || match[3] === undefined) throw new Error('Chapter ID is invalid.');
  const source = decodeURIComponent(match[1]);
  const episodeId = decodeURIComponent(match[2]);
  const episodeIndex = decodeURIComponent(match[3]);
  if ([source, episodeId, episodeIndex].some((value) => value === '' || value.length > 160)) throw new Error('Chapter ID is invalid.');
  return frozen({ source, episodeId, episodeIndex });
}

function searchable(value: Json): string {
  return [value.vod_name, value.name, value.title, value.vod_actor, value.vod_director, value.vod_class]
    .map(text).join(' ').toLocaleLowerCase('zh-CN');
}

function baseHeaders(extra: Readonly<Record<string, string>>): Record<string, string> {
  return { Accept: 'application/json', 'Accept-Encoding': 'gzip, deflate', 'Content-Type': 'application/json', 'User-Agent': userAgent, ...extra };
}

function authError(error: unknown): boolean {
  return /request sign|device_secret|device_id|unauthorized|401|request validation|app.?guard|signature|签名/u.test(error instanceof Error ? error.message : String(error));
}

function sha(value: string): Buffer { return createHash('sha256').update(value).digest(); }
function shaHex(value: string): string { return sha(value).toString('hex'); }
function hmacBase64Url(value: string, key: string): string { return createHmac('sha256', key).update(value).digest('base64url'); }
function safeUrl(value: string): string { try { const url = new URL(value); return /^https?:$/u.test(url.protocol) ? url.toString() : ''; } catch { return ''; } }
function cursorPage(cursor: string | null, scope: string): number { if (cursor === null) return 1; const raw = cursor.startsWith(`${scope}:`) ? cursor.slice(scope.length + 1) : ''; const page = Number(raw); if (!Number.isSafeInteger(page) || page < 2 || page > 50) throw new Error('Cursor is invalid.'); return page; }
function uniqueText(values: readonly string[]): string[] { const result: string[] = []; for (const value of values.map(clean)) if (value !== '' && !result.includes(value)) result.push(value); return result; }
function clean(value: string): string { return value.replace(/<[^>]*>/gu, ' ').replace(/[\s\u3000\u00a0]+/gu, ' ').trim(); }
function text(value: unknown): string { return typeof value === 'string' || typeof value === 'number' ? String(value) : ''; }
function array(value: unknown): unknown[] { return Array.isArray(value) ? value : []; }
function isRecord(value: unknown): value is Json { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function clamp(value: number): number { return Math.max(1, Math.min(50, Math.floor(value))); }
function frozen<T>(value: T): T { return Object.freeze(value); }
function requireContext(): Context { if (context === undefined) throw new Error('Source is not activated.'); return context; }
