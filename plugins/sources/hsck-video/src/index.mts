/** HSCK video source: MacCMS lists, neutral episode groups, and player-data decoding. */
type Json = Record<string, unknown>;
type Context = {
  readonly http: { fetch(input: string | URL, init?: RequestInit): Promise<Response> };
  readonly resource: { proxy(request: Record<string, unknown>): string };
  readonly log: { info(event: string): void; warn(event: string): void };
};

const base = 'https://hsck.la';
const headers = { Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,application/json,text/plain,*/*;q=0.8', 'Accept-Language': 'zh-CN,zh;q=0.9', Referer: `${base}/`, 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36' };
const categories = Object.freeze([['1', '麻豆'], ['2', '中字'], ['3', '国产'], ['4', '欧美'], ['5', '日韩']] as const);
let context: Context | undefined;

export async function activate(next: Context): Promise<void> { context = next; next.log.info('source_activated'); }
export async function search(request: { query: string; cursor: string | null; pageSize: number }) {
  if (request.cursor !== null) throw new Error('Search cursor is unsupported.'); if (request.query.trim() === '') return frozen({ items: [], nextCursor: null, totalCount: 0 });
  const json = await fetchJson(`${base}/index.php/ajax/suggest?mid=1&wd=${encodeURIComponent(request.query)}&page=1`);
  return frozen({ items: records(json.list).slice(0, clamp(request.pageSize)).map(suggestion), nextCursor: null, totalCount: null });
}
export async function searchSuggestions(_request: { cursor: string | null; pageSize: number }) { return frozen({ items: [], nextCursor: null }); }
export async function discover(request: { target: string | null; cursor: string | null; collectionId: string | null; pageSize: number }) {
  if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null) throw new Error('Initial discovery request is invalid.');
    return rootDocument(request.pageSize);
  }
  const category = categories.find(([id]) => request.target === `category:${id}`);
  if (category === undefined) throw new Error('Discovery target is invalid.'); const page = cursorPage(request.cursor, request.target); const [id, title] = category;
  const html = await fetchText(categoryUrl(id, page)); const collectionId = `video:${id}`; const values = parseList(html).slice(0, clamp(request.pageSize));
  const items = values.map((content) => frozen({ content, rank: null, metric: null, recommendation: null })); const continuation = values.length >= clamp(request.pageSize) && page < 50 ? frozen({ target: request.target, cursor: `${request.target}:${page + 1}` }) : null;
  if (request.collectionId !== null) { if (request.collectionId !== collectionId) throw new Error('Discovery collection is invalid.'); return frozen({ kind: 'append' as const, collectionId, items, continuation }); }
  return frozen({ kind: 'document' as const, document: { components: [{ type: 'section', id: `${collectionId}:section`, title, subtitle: null, icon: 'video', children: [{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation }] }] } });
}
export async function getDetail(request: { id: string }) { const id = contentId(request.id); const html = await fetchText(detailUrl(id)); return detail(parseDetail(html, id)); }
export async function getChapters(request: { id: string }) { const id = contentId(request.id); const groups = parseGroups(await fetchText(detailUrl(id)), id); return frozen({ items: groups.flatMap((group) => group.episodes), groups }); }
export async function getContent(request: { id: string; chapterId: string }) {
  const id = contentId(request.id); const chapter = parseChapterId(request.chapterId, id); const catalog = await getChapters({ id: request.id }); const selected = catalog.items.find((item) => item.id === request.chapterId);
  if (selected === undefined) throw new Error('Chapter ID is invalid.'); const page = playUrl(id, chapter.sid, chapter.nid); const player = parsePlayerData(await fetchText(page)); const upstream = playerUrl(player);
  if (!safeMediaUrl(upstream)) throw new Error('Playback address is unavailable.'); const resourceType = /\.m3u8(?:$|[?#])/iu.test(upstream) ? 'hls' : 'video'; const mediaHeaders = { Referer: page, 'User-Agent': headers['User-Agent'] };
  return frozen({ chapterId: request.chapterId, contentKind: 'video', title: selected.title, updatedAt: null, text: null, pages: [], media: { url: requireContext().resource.proxy({ kind: resourceType, url: upstream, headers: mediaHeaders }), resourceType, resourcePolicy: 'sessionOnly', expiresAt: null, mimeType: resourceType === 'hls' ? 'application/vnd.apple.mpegurl' : 'video/mp4', headers: mediaHeaders } });
}
export async function resource(_request: Record<string, unknown>) { return { status: 404, body: '' }; }

async function fetchText(url: string) { const response = await requireContext().http.fetch(url, { headers }); if (!response.ok) throw new Error('Source request failed.'); return response.text(); }
async function fetchJson(url: string): Promise<Json> { const text = await fetchText(url); const value: unknown = JSON.parse(text); if (!isObject(value)) throw new Error('Source response is invalid.'); return value; }
async function rootDocument(pageSize: number) {
  const limit = Math.min(clamp(pageSize), 10);
  const values = parseList(await fetchText(categoryUrl('1', 1))).slice(0, limit);
  const items = values.map((content) => frozen({ content, rank: null, metric: null, recommendation: null }));
  const components: object[] = [];
  if (items.length > 0) components.push({ type: 'section', id: 'video-featured', title: '热门视频', subtitle: '横版封面快速浏览', icon: 'hot', children: [{ type: 'contentCollection', id: 'video-featured-list', layout: 'coverGrid', items, continuation: null }] });
  components.push({ type: 'section', id: 'video-categories', title: '视频分类', subtitle: '按频道继续发现', icon: 'video', children: [{ type: 'categoryCollection', id: 'video-categories-list', layout: 'chips', categories: categories.map(([id, title]) => ({ id, title, target: `category:${id}`, count: null, url: null, icon: 'video' })) }] });
  return frozen({ kind: 'document' as const, document: { components } });
}
function suggestion(value: Json) { return summary(text(value.id), text(value.name), nullable(value.pic), null); }
function parseList(html: string) { const entries = listEntries(html); const unique = new Map<string, ReturnType<typeof summary>>(); for (const entry of entries) if (!unique.has(entry.id)) unique.set(entry.id, summary(entry.id, entry.title, entry.cover, null)); return [...unique.values()]; }
function listEntries(html: string) {
  const result: { id: string; title: string; cover: string | null }[] = [];
  for (const match of html.matchAll(/<a\b([^>]*)>([\s\S]*?)<\/a>/giu)) {
    const attributes = match[1] ?? ''; const body = match[2] ?? ''; const href = attribute(attributes, 'href');
    const id = /\/vod\/(?:detail|play)\/id\/(\d+)/iu.exec(href)?.[1]; if (id === undefined) continue;
    const image = /<img\b[^>]*>/iu.exec(body)?.[0] ?? '';
    const title = attribute(attributes, 'title') || attribute(image, 'alt') || strip(body) || `视频 ${id}`;
    const cover = attribute(attributes, 'data-original') || attribute(attributes, 'data-src') || attribute(attributes, 'data-lazy-src') || attribute(image, 'data-original') || attribute(image, 'data-src') || attribute(image, 'data-lazy-src') || attribute(image, 'src');
    result.push({ id, title, cover: cover === '' ? null : cover });
  }
  return result;
}
function parseDetail(html: string, id: string) { const title = firstText(html, /<h1[^>]*>([\s\S]*?)<\/h1>/iu) || firstText(html, /<title[^>]*>([\s\S]*?)<\/title>/iu); const cover = firstAttribute(html, /<meta[^>]+property=["']og:image["'][^>]*>/iu, 'content') || firstAttribute(html, /<img\b[^>]*>/iu, 'data-original') || firstAttribute(html, /<img\b[^>]*>/iu, 'src'); return summary(id, title || `视频 ${id}`, cover, null); }
function summary(id: string, title: string, cover: string | null, updatedAt: string | null) { if (!/^\d+$/u.test(id)) throw new Error('Source item has no ID.'); return frozen({ id: `video:${id}`, title: decode(title) || `视频 ${id}`, contentKind: 'video', author: null, url: detailUrl(id), coverUrl: absolute(cover), description: null, language: 'zh-CN', status: 'unknown', access: 'unknown', wordCount: null, chapterCount: null, publishedAt: null, updatedAt, latestChapter: null, categories: [], tags: [], attributes: [] }); }
function detail(item: ReturnType<typeof summary>) { return frozen({ ...item, aliases: [], catalogUrl: item.url }); }
function parseGroups(html: string, id: string) {
  const blocks = playlistBlocks(html); const groups = blocks.map((block, index) => groupFromLinks(block.html, id, block.title || `分组 ${index + 1}`, index)).filter((value) => value.episodes.length > 0);
  if (groups.length > 0) return groups; const fallback = groupFromLinks(html, id, '默认分组', 0); if (fallback.episodes.length === 0) throw new Error('No playable episodes found.'); return [fallback];
}
function playlistBlocks(html: string) {
  const titles = [...html.matchAll(/<(?:div|li|span)[^>]*class=["'][^"']*(?:tab-item|playlist-title)[^"']*["'][^>]*>([\s\S]*?)<\/(?:div|li|span)>/giu)].map((match) => strip(match[1] ?? ''));
  const blocks = [...html.matchAll(/<(?:div|ul|section)[^>]*(?:class=["'][^"']*(?:play-list|playlist)[^"']*["']|data-group=)[^>]*>([\s\S]*?)<\/(?:div|ul|section)>/giu)];
  return blocks.map((match, index) => ({ html: match[1] ?? '', title: attribute(match[0] ?? '', 'data-group') || titles[index] || '' }));
}
function groupFromLinks(html: string, id: string, title: string, order: number) { const episodes = links(html).filter((entry) => entry.id === id).map((entry, index) => frozen({ id: `video:${id}:${entry.sid}:${entry.nid}`, title: entry.title || `第${index + 1}集`, order: index, url: playUrl(id, entry.sid, entry.nid), volumeTitle: decode(title), wordCount: null, updatedAt: null, isLocked: null, attributes: [] })); const sid = episodes[0]?.id.split(':')[2] ?? String(order + 1); return frozen({ id: `group:${id}:${sid}`, title: decode(title), order, episodes }); }
function links(html: string) { const result: { id: string; sid: string; nid: string; title: string }[] = []; for (const match of html.matchAll(/<a\b([^>]*)>([\s\S]*?)<\/a>/giu)) { const href = attribute(match[1] ?? '', 'href'); const parsed = /\/vod\/play\/id\/(\d+)\/sid\/(\d+)\/nid\/(\d+)\.html/iu.exec(href); if (parsed?.[1] === undefined || parsed[2] === undefined || parsed[3] === undefined) continue; result.push({ id: parsed[1], sid: parsed[2], nid: parsed[3], title: attribute(match[1] ?? '', 'title') || strip(match[2] ?? '') }); } return result; }
function parsePlayerData(html: string): Json { const start = html.search(/(?:var\s+)?player_\w+\s*=\s*\{/iu); if (start < 0) throw new Error('Player data is unavailable.'); const brace = html.indexOf('{', start); const json = balancedObject(html, brace); const value: unknown = JSON.parse(json); if (!isObject(value)) throw new Error('Player data is invalid.'); return value; }
function balancedObject(text: string, start: number) { let depth = 0; let quote = ''; let escaped = false; for (let index = start; index < text.length; index += 1) { const char = text[index] ?? ''; if (quote !== '') { if (escaped) escaped = false; else if (char === '\\') escaped = true; else if (char === quote) quote = ''; continue; } if (char === '"' || char === "'") { quote = char; continue; } if (char === '{') depth += 1; if (char === '}') { depth -= 1; if (depth === 0) return text.slice(start, index + 1); } } throw new Error('Player data is incomplete.'); }
function playerUrl(data: Json) { const raw = text(data.url); const encrypt = Number(data.encrypt ?? 0); const decoded = encrypt === 2 ? Buffer.from(raw, 'base64').toString('utf8') : raw; return legacyDecode(decoded); }
function legacyDecode(value: string) { try { return decodeURIComponent(value); } catch { try { return unescape(value); } catch { return value; } } }
function categoryUrl(id: string, page: number) { return page <= 1 ? `${base}/index.php/vod/type/id/${id}.html` : `${base}/index.php/vod/type/id/${id}/page/${page}.html`; }
function detailUrl(id: string) { return `${base}/index.php/vod/detail/id/${id}.html`; }
function playUrl(id: string, sid: string, nid: string) { return `${base}/index.php/vod/play/id/${id}/sid/${sid}/nid/${nid}.html`; }
function contentId(id: string) { const match = /^video:(\d+)$/u.exec(id); if (match?.[1] === undefined) throw new Error('Content ID is invalid.'); return match[1]; }
function parseChapterId(id: string, content: string) { const match = new RegExp(`^video:${content}:(\\d+):(\\d+)$`, 'u').exec(id); if (match?.[1] === undefined || match[2] === undefined) throw new Error('Chapter ID is invalid.'); return { sid: match[1], nid: match[2] }; }
function cursorPage(cursor: string | null, target: string) { if (cursor === null) return 1; const value = Number(new RegExp(`^${escape(target)}:(\\d+)$`, 'u').exec(cursor)?.[1]); if (!Number.isSafeInteger(value) || value < 2 || value > 50) throw new Error('Discovery cursor is invalid.'); return value; }
function safeMediaUrl(value: string) { try { const url = new URL(value); return (url.protocol === 'https:' || url.protocol === 'http:') && url.username === '' && url.password === ''; } catch { return false; } }
function absolute(value: string | null) { if (value === null || value === '') return null; try { return new URL(value.replaceAll('\\/', '/'), base).toString(); } catch { return null; } }
function attribute(text: string, name: string) { return new RegExp(`${escape(name)}=["']([^"']+)["']`, 'iu').exec(text)?.[1] ?? ''; }
function firstAttribute(html: string, pattern: RegExp, name: string) { const match = pattern.exec(html); return match === null ? '' : attribute(match[0], name); }
function firstText(html: string, pattern: RegExp) { return strip(pattern.exec(html)?.[1] ?? ''); }
function strip(value: string) { return decode(value.replace(/<script[\s\S]*?<\/script>/giu, '').replace(/<style[\s\S]*?<\/style>/giu, '').replace(/<[^>]+>/gu, ' ').replace(/\s+/gu, ' ')).trim(); }
function decode(value: string) { return value.replace(/&amp;/giu, '&').replace(/&quot;/giu, '"').replace(/&#39;/giu, "'").replace(/&lt;/giu, '<').replace(/&gt;/giu, '>').replace(/&nbsp;/giu, ' '); }
function clamp(value: number) { return Math.max(1, Math.min(100, Math.floor(value))); }
function text(value: unknown) { return typeof value === 'string' ? value.trim() : typeof value === 'number' ? String(value) : ''; }
function nullable(value: unknown) { const result = text(value); return result === '' ? null : result; }
function records(value: unknown): Json[] { return Array.isArray(value) ? value.filter(isObject) : []; }
function isObject(value: unknown): value is Json { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function frozen<T>(value: T): T { return Object.freeze(value); }
function escape(value: string) { return value.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&'); }
function requireContext(): Context { if (context === undefined) throw new Error('Source is not activated.'); return context; }
