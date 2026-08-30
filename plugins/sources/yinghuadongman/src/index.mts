/**
 * Yinghua Dongman video source.
 *
 * Owns the public site routes, stable video/line/episode identities, source-priority
 * line ordering, HTML parsing and MCUE player decryption. Media bytes always remain
 * in Runtime's resource proxy.
 */
import { createDecipheriv, createHash } from 'node:crypto';

type Json = Record<string, unknown>;
type Context = {
  readonly http: { fetch(input: string | URL, init?: RequestInit): Promise<Response> };
  readonly resource: { proxy(request: Record<string, unknown>): string };
  readonly log: { info(event: string): void; warn(event: string): void };
};

const base = 'https://www.yinhuadm.xyz';
const playerBase = 'https://player.mcue.cc';
const playerSalt = 'lemon';
const pageHeaders = Object.freeze({
  Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,application/json,text/plain,*/*;q=0.8',
  'Accept-Language': 'zh-CN,zh;q=0.9',
  Referer: `${base}/`,
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36',
});
const categories = Object.freeze([
  ['today', '今日更新', '/label/new.html'],
  ['hot', '热榜', '/label/hot.html'],
  ['week', '本周追番', '/label/week.html'],
  ['new', '新片上线', '/s/1.html'],
] as const);
let context: Context | undefined;

export async function activate(next: Context): Promise<void> {
  context = next;
  next.log.info('source_activated');
}

export async function search(request: { query: string; cursor: string | null; pageSize: number }) {
  const query = request.query.trim();
  if (query === '') return frozen({ items: [], nextCursor: null, totalCount: 0 });
  const page = searchPage(request.cursor);
  const path = page === 1
    ? `/vch/${encodeURIComponent(query)}.html`
    : `/vch/${encodeURIComponent(query)}/page/${page}.html`;
  const items = parseListing(await fetchText(`${base}${path}`)).slice(0, clamp(request.pageSize));
  return frozen({
    items,
    nextCursor: items.length >= clamp(request.pageSize) && page < 50 ? `search:${page + 1}` : null,
    totalCount: null,
  });
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
    return rootDocument(request.pageSize);
  }
  const category = categories.find(([id]) => request.target === `category:${id}`);
  if (category === undefined) throw new Error('Discovery target is invalid.');
  const page = discoveryPage(request.cursor, request.target);
  const [, title, route] = category;
  const collectionId = `video:${category[0]}`;
  const values = parseListing(await fetchText(`${base}${pagedRoute(route, page)}`)).slice(0, clamp(request.pageSize));
  const items = values.map((content) => frozen({ content, rank: null, metric: null, recommendation: null }));
  const continuation = values.length >= clamp(request.pageSize) && page < 50
    ? frozen({ target: request.target, cursor: `${request.target}:${page + 1}` })
    : null;
  if (request.collectionId !== null) {
    if (request.collectionId !== collectionId) throw new Error('Discovery collection is invalid.');
    return frozen({ kind: 'append' as const, collectionId, items, continuation });
  }
  return frozen({
    kind: 'document' as const,
    document: {
      components: [{
        type: 'section', id: `${collectionId}:section`, title, subtitle: null, icon: 'video',
        children: [{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation }],
      }],
    },
  });
}

export async function getDetail(request: { id: string }) {
  const id = contentId(request.id);
  return parseDetail(await fetchText(detailUrl(id)), id);
}

export async function getChapters(request: { id: string }) {
  const id = contentId(request.id);
  const groups = parseGroups(await fetchText(detailUrl(id)), id);
  return frozen({ items: groups.flatMap((group) => group.episodes), groups });
}

export async function getContent(request: { id: string; chapterId: string }) {
  const id = contentId(request.id);
  const chapter = parseChapterId(request.chapterId, id);
  const catalog = await getChapters({ id: request.id });
  const selected = catalog.items.find((item) => item.id === request.chapterId);
  if (selected === undefined) throw new Error('Chapter ID is invalid.');
  const page = playUrl(id, chapter.line, chapter.episode);
  const player = parsePlayerData(await fetchText(page));
  const resolved = await resolvePlayerUrl(player, page);
  if (!safeMediaUrl(resolved.url)) throw new Error('Playback address is unavailable.');
  const resourceType = /\.m3u8(?:$|[?#])/iu.test(resolved.url) ? 'hls' : 'video';
  const mediaHeaders = { Referer: resolved.referer, 'User-Agent': pageHeaders['User-Agent'] };
  return frozen({
    chapterId: request.chapterId,
    contentKind: 'video',
    title: selected.title,
    updatedAt: null,
    text: null,
    pages: [],
    media: {
      url: requireContext().resource.proxy({ kind: resourceType, url: resolved.url, headers: mediaHeaders }),
      resourceType,
      resourcePolicy: 'sessionOnly',
      expiresAt: null,
      mimeType: resourceType === 'hls' ? 'application/vnd.apple.mpegurl' : 'video/mp4',
      headers: mediaHeaders,
    },
  });
}

async function rootDocument(pageSize: number) {
  const limit = Math.min(clamp(pageSize), 12);
  const values = parseListing(await fetchText(`${base}/label/new.html`)).slice(0, limit);
  const items = values.map((content) => frozen({ content, rank: null, metric: null, recommendation: null }));
  const components: object[] = [];
  if (items.length > 0) {
    components.push({
      type: 'section', id: 'video-featured', title: '今日更新', subtitle: '近期更新的动漫', icon: 'hot',
      children: [{ type: 'contentCollection', id: 'video-featured-list', layout: 'coverGrid', items, continuation: null }],
    });
  }
  components.push({
    type: 'section', id: 'video-categories', title: '动漫分类', subtitle: '按栏目继续发现', icon: 'video',
    children: [{
      type: 'categoryCollection', id: 'video-categories-list', layout: 'chips',
      categories: categories.map(([id, title]) => ({ id, title, target: `category:${id}`, count: null, url: null, icon: 'video' })),
    }],
  });
  return frozen({ kind: 'document' as const, document: { components } });
}

async function fetchText(url: string): Promise<string> {
  let lastStatus = 0;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    try {
      const response = await requireContext().http.fetch(url, { headers: pageHeaders });
      lastStatus = response.status;
      if (response.ok) return await response.text();
    } catch {
      requireContext().log.warn('source_request_retry');
    }
  }
  if (lastStatus > 0) throw new Error(`Source request failed with status ${lastStatus}.`);
  throw new Error('Source request failed.');
}

function parseListing(html: string) {
  const unique = new Map<string, ReturnType<typeof summary>>();
  for (const match of html.matchAll(/<a\b([^>]*)>([\s\S]*?)<\/a>/giu)) {
    const attributes = match[1] ?? '';
    const body = match[2] ?? '';
    const href = attribute(attributes, 'href');
    const id = /\/v\/(\d+)\.html(?:[?#]|$)/iu.exec(href)?.[1];
    if (id === undefined || unique.has(id)) continue;
    const image = /<img\b[^>]*>/iu.exec(body)?.[0] ?? '';
    const title = cleanTitle(
      attribute(attributes, 'title') ||
      attribute(image, 'alt') ||
      firstText(body, /<[^>]*class=["'][^"']*module-poster-item-title[^"']*["'][^>]*>([\s\S]*?)<\/[^>]+>/iu) ||
      strip(body),
    );
    if (title === '') continue;
    const cover = attribute(image, 'data-original') || attribute(image, 'data-src') || attribute(image, 'src');
    const latest = firstText(body, /<[^>]*class=["'][^"']*module-item-note[^"']*["'][^>]*>([\s\S]*?)<\/[^>]+>/iu);
    unique.set(id, summary(id, title, cover, latest || null));
  }
  return [...unique.values()];
}

function parseDetail(html: string, id: string) {
  const title = cleanTitle(firstText(html, /<h1\b[^>]*>([\s\S]*?)<\/h1>/iu)) || `视频 ${id}`;
  const coverContainer = /<[^>]*class=["'][^"']*(?:module-item-cover|module-item-pic)[^"']*["'][^>]*>([\s\S]*?)<\/[^>]+>/iu.exec(html)?.[1] ?? '';
  const coverImage = /<img\b[^>]*>/iu.exec(coverContainer)?.[0] ?? '';
  const cover = firstAttribute(html, /<meta\b[^>]*property=["']og:image["'][^>]*>/iu, 'content') ||
    attribute(coverImage, 'data-original') || attribute(coverImage, 'data-src') || attribute(coverImage, 'src');
  const description = firstText(html, /<[^>]*class=["'][^"']*(?:module-info-introduction|vod_content)[^"']*["'][^>]*>([\s\S]*?)<\/[^>]+>/iu);
  const latest = firstText(html, /<[^>]*class=["'][^"']*module-item-note[^"']*["'][^>]*>([\s\S]*?)<\/[^>]+>/iu);
  const tags = uniqueText([...html.matchAll(/<a\b([^>]*)>([\s\S]*?)<\/a>/giu)]
    .filter((match) => /\/w\//iu.test(attribute(match[1] ?? '', 'href')))
    .map((match) => strip(match[2] ?? '')));
  const item = summary(id, title, cover, latest || null, description || null, tags);
  return frozen({ ...item, aliases: [], catalogUrl: item.url });
}

function summary(
  id: string,
  title: string,
  cover: string | null,
  latestChapterTitle: string | null,
  description: string | null = null,
  tags: string[] = [],
) {
  if (!/^\d+$/u.test(id)) throw new Error('Source item has no ID.');
  return frozen({
    id: `video:${id}`,
    title: decode(title) || `视频 ${id}`,
    contentKind: 'video',
    author: null,
    url: detailUrl(id),
    coverUrl: absolute(cover),
    description,
    language: 'zh-CN',
    status: 'unknown',
    access: 'unknown',
    wordCount: null,
    chapterCount: null,
    publishedAt: null,
    updatedAt: null,
    latestChapter: projectLatestChapter(latestChapterTitle),
    categories: tags,
    tags,
    attributes: [],
  });
}

function parseGroups(html: string, id: string) {
  const byLine = new Map<number, { episode: number; title: string }[]>();
  const seen = new Set<string>();
  for (const match of html.matchAll(/<a\b([^>]*)>([\s\S]*?)<\/a>/giu)) {
    const href = attribute(match[1] ?? '', 'href');
    const parsed = new RegExp(`/p/${id}-(\\d+)-(\\d+)\\.html`, 'iu').exec(href);
    if (parsed?.[1] === undefined || parsed[2] === undefined) continue;
    const line = Number(parsed[1]);
    const episode = Number(parsed[2]);
    const key = `${line}:${episode}`;
    if (!Number.isSafeInteger(line) || !Number.isSafeInteger(episode) || seen.has(key)) continue;
    seen.add(key);
    const title = cleanEpisodeTitle(attribute(match[1] ?? '', 'title') || strip(match[2] ?? ''), episode);
    const entries = byLine.get(line) ?? [];
    entries.push({ episode, title });
    byLine.set(line, entries);
  }
  const groups = [...byLine.entries()].map(([line, entries], groupOrder) => {
    entries.sort((left, right) => left.episode - right.episode);
    const groupTitle = `线路 ${line}`;
    const episodes = entries.map((entry, order) => frozen({
      id: `video:${id}:${line}:${entry.episode}`,
      title: entry.title,
      order,
      url: playUrl(id, String(line), String(entry.episode)),
      volumeTitle: groupTitle,
      wordCount: null,
      updatedAt: null,
      isLocked: null,
      attributes: [],
    }));
    return frozen({ id: `group:${id}:${line}`, title: groupTitle, order: groupOrder, episodes });
  });
  if (groups.length === 0) throw new Error('No playable episodes found.');
  return groups;
}

function parsePlayerData(html: string): Json {
  const start = html.search(/(?:var\s+)?player_\w+\s*=\s*\{/iu);
  if (start < 0) throw new Error('Player data is unavailable.');
  const brace = html.indexOf('{', start);
  const value: unknown = JSON.parse(balancedObject(html, brace));
  if (!isObject(value)) throw new Error('Player data is invalid.');
  return value;
}

async function resolvePlayerUrl(player: Json, playPage: string) {
  const raw = text(player.url);
  const encrypt = Number(player.encrypt ?? 0);
  const decoded = encrypt === 2
    ? legacyDecode(Buffer.from(raw, 'base64').toString('utf8'))
    : encrypt === 1 ? legacyDecode(raw) : raw;
  if (safeMediaUrl(decoded)) return { url: decoded, referer: playPage };
  if (decoded === '') throw new Error('Playback address is unavailable.');
  const playerPage = `${playerBase}/yinhua/?url=${encodeURIComponent(decoded)}`;
  const decrypted = decryptMcuePlayerHtml(await fetchText(playerPage));
  return { url: decrypted, referer: playerPage };
}

function decryptMcuePlayerHtml(html: string): string {
  const cipher = extractMcueCipher(html);
  const seed = buildMcueSeed(html);
  if (cipher === '' || seed === '') throw new Error('Player response is invalid.');
  const digest = createHash('md5').update(seed + playerSalt).digest('hex');
  const decipher = createDecipheriv('aes-128-cbc', Buffer.from(digest.slice(16)), Buffer.from(digest.slice(0, 16)));
  const decrypted = decipher.update(cipher, 'base64', 'utf8') + decipher.final('utf8');
  return decodeJsString(decrypted.trim().replace(/^(?:"|')|(?:"|')$/gu, ''));
}

function buildMcueSeed(html: string): string {
  const order = extractNowMetaId(html, (tag) => /^utf-8$/iu.test(attribute(tag, 'charset')));
  const values = extractNowMetaId(html, (tag) => /^viewport$/iu.test(attribute(tag, 'name')));
  if (order === '' || values === '' || order.length !== values.length) return '';
  return [...order].map((id, index) => ({ id: Number(id), value: values[index] ?? '' }))
    .sort((left, right) => left.id - right.id).map((entry) => entry.value).join('');
}

function extractNowMetaId(html: string, predicate: (tag: string) => boolean): string {
  for (const match of html.matchAll(/<meta\b[^>]*>/giu)) {
    const tag = match[0];
    if (!predicate(tag)) continue;
    const id = attribute(tag, 'id');
    if (id.startsWith('now_')) return id.slice(4);
  }
  return '';
}

function extractMcueCipher(html: string): string {
  return decodeJsString(/["']url["']\s*:\s*["']([^"']+)["']/iu.exec(html)?.[1] ?? '');
}

function balancedObject(value: string, start: number): string {
  let depth = 0;
  let quote = '';
  let escaped = false;
  for (let index = start; index < value.length; index += 1) {
    const char = value[index] ?? '';
    if (quote !== '') {
      if (escaped) escaped = false;
      else if (char === '\\') escaped = true;
      else if (char === quote) quote = '';
      continue;
    }
    if (char === '"' || char === "'") { quote = char; continue; }
    if (char === '{') depth += 1;
    if (char === '}' && --depth === 0) return value.slice(start, index + 1);
  }
  throw new Error('Player data is incomplete.');
}

function contentId(id: string): string {
  const value = /^video:(\d+)$/u.exec(id)?.[1];
  if (value === undefined) throw new Error('Content ID is invalid.');
  return value;
}

function parseChapterId(id: string, content: string) {
  const match = new RegExp(`^video:${content}:(\\d+):(\\d+)$`, 'u').exec(id);
  if (match?.[1] === undefined || match[2] === undefined) throw new Error('Chapter ID is invalid.');
  return { line: match[1], episode: match[2] };
}

function discoveryPage(cursor: string | null, target: string): number {
  if (cursor === null) return 1;
  const page = Number(new RegExp(`^${escape(target)}:(\\d+)$`, 'u').exec(cursor)?.[1]);
  if (!Number.isSafeInteger(page) || page < 2 || page > 50) throw new Error('Discovery cursor is invalid.');
  return page;
}

function searchPage(cursor: string | null): number {
  if (cursor === null) return 1;
  const page = Number(/^search:(\d+)$/u.exec(cursor)?.[1]);
  if (!Number.isSafeInteger(page) || page < 2 || page > 50) throw new Error('Search cursor is invalid.');
  return page;
}

function pagedRoute(route: string, page: number): string {
  return page === 1 ? route : route.replace(/\.html$/u, `/${page}.html`);
}

function detailUrl(id: string): string { return `${base}/v/${id}.html`; }
function playUrl(id: string, line: string, episode: string): string { return `${base}/p/${id}-${line}-${episode}.html`; }
function safeMediaUrl(value: string): boolean {
  try {
    const url = new URL(value);
    return ['https:', 'http:'].includes(url.protocol) && url.username === '' && url.password === '';
  } catch { return false; }
}
function absolute(value: string | null): string | null {
  if (value === null || value === '') return null;
  try { return new URL(decodeJsString(value), base).toString(); } catch { return null; }
}
function cleanTitle(value: string): string {
  const title = strip(value);
  if (title === '' || title.length > 120) return '';
  return /^(?:更新至第?\d+集|更新至\d+集|已?完结|全\d+集|完结|动漫|HD中字|HD|详情|立即播放|播放)$/u.test(title) ? '' : title;
}
function cleanEpisodeTitle(value: string, episode: number): string {
  const title = strip(value);
  return title === '' || !/第|集|话|期/u.test(title) ? `第${String(episode).padStart(2, '0')}集` : title;
}
function projectLatestChapter(value: string | null) {
  const title = value === null ? '' : strip(value);
  if (title === '' || title.length > 256) return null;
  return frozen({ id: null, title, updatedAt: null, url: null });
}
function attribute(value: string, name: string): string {
  const quoted = new RegExp(`\\s${escape(name)}\\s*=\\s*(["'])(.*?)\\1`, 'iu').exec(value);
  if (quoted?.[2] !== undefined) return decodeJsString(quoted[2]);
  return new RegExp(`\\s${escape(name)}\\s*=\\s*([^\\s>]+)`, 'iu').exec(value)?.[1] ?? '';
}
function firstAttribute(html: string, pattern: RegExp, name: string): string {
  const match = pattern.exec(html);
  return match === null ? '' : attribute(match[0], name);
}
function firstText(html: string, pattern: RegExp): string { return strip(pattern.exec(html)?.[1] ?? ''); }
function strip(value: string): string {
  return decode(value.replace(/<script[\s\S]*?<\/script>/giu, '').replace(/<style[\s\S]*?<\/style>/giu, '')
    .replace(/<[^>]+>/gu, ' ').replace(/\s+/gu, ' ')).trim();
}
function decode(value: string): string {
  return value.replace(/&amp;/giu, '&').replace(/&quot;/giu, '"').replace(/&#(?:39|x27);/giu, "'")
    .replace(/&lt;/giu, '<').replace(/&gt;/giu, '>').replace(/&nbsp;/giu, ' ');
}
function decodeJsString(value: string): string {
  return value.replace(/\\u([0-9a-f]{4})/giu, (_match, hex: string) => String.fromCharCode(Number.parseInt(hex, 16)))
    .replace(/\\\//gu, '/').replace(/\\"/gu, '"').replace(/\\\\/gu, '\\');
}
function legacyDecode(value: string): string { try { return decodeURIComponent(value); } catch { return value; } }
function uniqueText(values: string[]): string[] { return [...new Set(values.filter((value) => value !== ''))]; }
function clamp(value: number): number { return Math.max(1, Math.min(100, Math.floor(value))); }
function text(value: unknown): string { return typeof value === 'string' ? value.trim() : typeof value === 'number' ? String(value) : ''; }
function isObject(value: unknown): value is Json { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function frozen<T>(value: T): T { return Object.freeze(value); }
function escape(value: string): string { return value.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&'); }
function requireContext(): Context { if (context === undefined) throw new Error('Source is not activated.'); return context; }
