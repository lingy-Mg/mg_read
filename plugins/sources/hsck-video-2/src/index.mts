/**
 * 黄色仓库 2 视频数据源。
 *
 * 职责：解析镜像站的分类、搜索、详情与单集 HLS 播放信息。
 * 生命周期：activate 仅保存宿主公开上下文；所有网络访问发生在 Source 调用期间。
 * IO：HTML 由 ctx.http 获取，视频资源只登记到 ctx.resource.proxy。
 * 状态所有权：插件只持有当前宿主上下文，并合并同一详情的并发请求；不缓存正文、媒体、Cookie 或签名地址。
 * 注意：稳定 ID 不包含域名；镜像 origin 只由本文件的 base 常量拥有。
 */
type Context = {
  readonly http: { fetch(input: string | URL, init?: RequestInit): Promise<Response> };
  readonly resource: { proxy(request: Record<string, unknown>): string };
  readonly log: { info(event: string): void; warn(event: string): void };
};

type Category = { readonly code: string; readonly title: string };
type ContentSummary = ReturnType<typeof summary>;
type CursorState = { readonly page: number; readonly offset: number };

const base = 'https://hsck123.25img.com';
const searchKey = 'ndafeoafa';
const headers = {
  Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,text/plain,*/*;q=0.8',
  'Accept-Language': 'zh-CN,zh;q=0.9',
  Referer: base + '/',
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36',
};
const categories = Object.freeze<Category[]>([
  { code: 'ycgc', title: '国产新片' },
  { code: 'gcjp', title: '國產舊篇' },
  { code: 'wz', title: '无码中文字幕' },
  { code: 'yz', title: '有码中文字幕' },
  { code: 'rw', title: '日本无码' },
  { code: 'ry', title: '日本有码' },
  { code: 'qp', title: '骑兵破解' },
  { code: 'gc', title: '国产视频' },
  { code: 'om', title: '欧美高清' },
  { code: 'dm', title: '动漫剧情' },
]);
let context: Context | undefined;
const detailLoads = new Map<string, Promise<string>>();

export async function activate(next: Context): Promise<void> {
  context = next;
  detailLoads.clear();
  next.log.info('source_activated');
}

export async function search(request: { query: string; cursor: string | null; pageSize: number }) {
  const query = request.query.trim();
  if (query === '') return frozen({ items: [], nextCursor: null, totalCount: 0 });
  const state = parseCursor(request.cursor, 'search');
  const html = await fetchText(searchUrl(query, state.page));
  const values = parseList(html);
  const page = paginate(values, clamp(request.pageSize), state, 'search', totalPages(html));
  return frozen({ items: page.items, nextCursor: page.nextCursor, totalCount: null });
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
  const category = categoryForTarget(request.target);
  const state = parseCursor(request.cursor, 'category:' + category.code);
  const html = await fetchText(categoryUrl(category.code, state.page));
  const values = parseList(html);
  const collectionId = 'video:' + category.code;
  const page = paginate(values, clamp(request.pageSize), state, 'category:' + category.code, totalPages(html));
  const items = page.items.map((content) => frozen({ content, rank: null, metric: null, recommendation: null }));
  const continuation = page.nextCursor === null
    ? null
    : frozen({ target: request.target, cursor: page.nextCursor });
  if (request.collectionId !== null) {
    if (request.collectionId !== collectionId) throw new Error('Discovery collection is invalid.');
    return frozen({ kind: 'append' as const, collectionId, items, continuation });
  }
  return frozen({
    kind: 'document' as const,
    document: {
      components: [{
        type: 'section',
        id: collectionId + ':section',
        title: category.title,
        subtitle: null,
        icon: 'video',
        children: [{
          type: 'contentCollection',
          id: collectionId,
          layout: 'coverGrid',
          items,
          continuation,
        }],
      }],
    },
  });
}

export async function getDetail(request: { id: string }) {
  const id = contentId(request.id);
  return parseDetail(await fetchDetail(id), id).item;
}

export async function getChapters(request: { id: string }) {
  const id = contentId(request.id);
  const parsed = parseDetail(await fetchDetail(id), id);
  const episode = frozen({
    id: chapterId(id),
    title: '正片',
    order: 0,
    url: detailUrl(id),
    volumeTitle: '默认线路',
    wordCount: null,
    updatedAt: parsed.item.updatedAt,
    isLocked: null,
    attributes: [],
  });
  const group = frozen({
    id: 'group:' + id + ':main',
    title: '默认线路',
    order: 0,
    episodes: [episode],
  });
  return frozen({ items: [episode], groups: [group] });
}

export async function getContent(request: { id: string; chapterId: string }) {
  const id = contentId(request.id);
  if (request.chapterId !== chapterId(id)) throw new Error('Chapter ID is invalid.');
  const pageUrl = detailUrl(id);
  const parsed = parseDetail(await fetchDetail(id), id);
  if (parsed.mediaUrl === null || !safeMediaUrl(parsed.mediaUrl)) throw new Error('Playback address is unavailable.');
  const resourceType = /\.m3u8(?:$|[?#])/iu.test(parsed.mediaUrl) ? 'hls' : 'video';
  const mediaHeaders = { Referer: pageUrl, 'User-Agent': headers['User-Agent'] };
  return frozen({
    chapterId: request.chapterId,
    contentKind: 'video',
    title: parsed.item.title,
    updatedAt: parsed.item.updatedAt,
    text: null,
    pages: [],
    media: {
      url: requireContext().resource.proxy({
        kind: resourceType,
        url: parsed.mediaUrl,
        headers: mediaHeaders,
      }),
      resourceType,
      resourcePolicy: 'sessionOnly',
      expiresAt: null,
      mimeType: resourceType === 'hls' ? 'application/vnd.apple.mpegurl' : 'video/mp4',
      headers: mediaHeaders,
    },
  });
}

async function rootDocument(pageSize: number) {
  const html = await fetchText(base + '/');
  const values = parseList(html).slice(0, Math.min(clamp(pageSize), 10));
  const items = values.map((content) => frozen({ content, rank: null, metric: null, recommendation: null }));
  const counts = categoryCounts(html);
  const components: object[] = [];
  if (items.length > 0) {
    components.push({
      type: 'section',
      id: 'video-featured',
      title: '热门视频',
      subtitle: '镜像站当前更新',
      icon: 'hot',
      children: [{
        type: 'contentCollection',
        id: 'video-featured-list',
        layout: 'coverGrid',
        items,
        continuation: null,
      }],
    });
  }
  components.push({
    type: 'section',
    id: 'video-categories',
    title: '视频分类',
    subtitle: '按频道继续发现',
    icon: 'video',
    children: [{
      type: 'categoryCollection',
      id: 'video-categories-list',
      layout: 'chips',
      categories: categories.map((category) => ({
        id: category.code,
        title: category.title,
        target: 'category:' + category.code,
        count: counts.get(category.code) ?? null,
        url: null,
        icon: 'video',
      })),
    }],
  });
  return frozen({ kind: 'document' as const, document: { components } });
}

async function fetchText(url: string) {
  let lastStatus = 0;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    if (attempt > 0) await new Promise<void>((resolve) => setTimeout(resolve, attempt * 100));
    try {
      const response = await requireContext().http.fetch(url, { headers });
      lastStatus = response.status;
      if (response.ok) return await response.text();
      if (response.status < 500) break;
    } catch {
      requireContext().log.warn('source_request_retry');
    }
  }
  if (lastStatus > 0) throw new Error('Source request failed with status ' + lastStatus + '.');
  throw new Error('Source request failed.');
}

async function fetchDetail(id: string) {
  const existing = detailLoads.get(id);
  if (existing !== undefined) return existing;
  const request = fetchText(detailUrl(id));
  detailLoads.set(id, request);
  try {
    return await request;
  } finally {
    if (detailLoads.get(id) === request) detailLoads.delete(id);
  }
}

function parseList(html: string): ContentSummary[] {
  const unique = new Map<string, ContentSummary>();
  for (const match of html.matchAll(/<a\b([^>]*)>([\s\S]*?)<\/a>/giu)) {
    const attributes = match[1] ?? '';
    const href = attribute(attributes, 'href');
    const id = /\/view\/\?id=([a-z0-9_-]+)/iu.exec(href)?.[1];
    if (id === undefined) continue;
    const body = match[2] ?? '';
    const image = /<img\b[^>]*>/iu.exec(body)?.[0] ?? '';
    const title = attribute(attributes, 'title') || attribute(image, 'alt') || strip(body) || ('视频 ' + id);
    const cover = attribute(attributes, 'data-original')
      || attribute(attributes, 'data-src')
      || attribute(image, 'data-original')
      || attribute(image, 'data-src')
      || attribute(image, 'src');
    const candidate = summary(id, title, cover === '' ? null : cover, null, null);
    const previous = unique.get(id);
    if (previous === undefined || (previous.coverUrl === null && candidate.coverUrl !== null)) unique.set(id, candidate);
  }
  return [...unique.values()];
}

function parseDetail(html: string, id: string) {
  const headings = [...html.matchAll(/<h3\b[^>]*class=["'][^"']*\btitle\b[^"']*["'][^>]*>([\s\S]*?)<\/h3>/giu)]
    .map((match) => strip(match[1] ?? ''))
    .filter((value) => value !== '' && value !== '目录' && value !== '为你推荐');
  const videoTag = /<img\b[^>]*id=["']video_img["'][^>]*>/iu.exec(html)?.[0] ?? '';
  const poster = attribute(videoTag, 'alt') || null;
  const mediaUrl = absolute(attribute(videoTag, 'src'));
  const updatedAt = dateTimestamp(/时间\s*[：:]\s*(\d{4}-\d{2}-\d{2})/u.exec(strip(html))?.[1]);
  const item = summary(id, headings[0] || ('视频 ' + id), poster, updatedAt, 1);
  return frozen({ item: frozen({ ...item, aliases: [], catalogUrl: item.url }), mediaUrl });
}

function summary(id: string, title: string, cover: string | null, updatedAt: string | null, chapterCount: number | null) {
  if (!/^[a-z0-9_-]+$/iu.test(id)) throw new Error('Source item has no ID.');
  return frozen({
    id: 'video:' + id,
    title: decode(title) || ('视频 ' + id),
    contentKind: 'video',
    author: null,
    url: detailUrl(id),
    coverUrl: absolute(cover),
    description: null,
    language: 'zh-CN',
    status: 'unknown',
    access: 'unknown',
    wordCount: null,
    chapterCount,
    publishedAt: null,
    updatedAt,
    latestChapter: null,
    categories: [],
    tags: [],
    attributes: [],
  });
}

function dateTimestamp(value: string | undefined) {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/u.exec(value ?? '');
  if (match === null) return null;
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const parsed = new Date(Date.UTC(year, month - 1, day));
  if (parsed.getUTCFullYear() !== year || parsed.getUTCMonth() !== month - 1 || parsed.getUTCDate() !== day) return null;
  return value + 'T00:00:00+08:00';
}

function categoryCounts(html: string) {
  const result = new Map<string, number>();
  for (const match of html.matchAll(/<a\b([^>]*)>([\s\S]*?)<\/a>/giu)) {
    const code = /[?&]type=([a-z0-9_-]+)/iu.exec(attribute(match[1] ?? '', 'href'))?.[1];
    const countText = /class=["'][^"']*\bcount\b[^"']*["'][^>]*>\s*(\d+)/iu.exec(match[2] ?? '')?.[1];
    if (code === undefined || countText === undefined) continue;
    const count = Number(countText);
    if (Number.isSafeInteger(count) && count >= 0) result.set(code, count);
  }
  return result;
}

function paginate<T>(values: readonly T[], limit: number, state: CursorState, prefix: string, pages: number) {
  const end = Math.min(values.length, state.offset + limit);
  const items = values.slice(state.offset, end);
  let nextCursor: string | null = null;
  if (end < values.length) nextCursor = prefix + ':' + state.page + ':' + end;
  else if (state.page < pages) nextCursor = prefix + ':' + (state.page + 1) + ':0';
  return frozen({ items, nextCursor });
}

function parseCursor(cursor: string | null, prefix: string): CursorState {
  if (cursor === null) return frozen({ page: 1, offset: 0 });
  const pattern = new RegExp('^' + escape(prefix) + ':(\\d+):(\\d+)$', 'u');
  const match = pattern.exec(cursor);
  const page = Number(match?.[1]);
  const offset = Number(match?.[2]);
  if (!Number.isSafeInteger(page) || page < 1 || page > 10000
      || !Number.isSafeInteger(offset) || offset < 0 || offset > 1000) {
    throw new Error('Source cursor is invalid.');
  }
  return frozen({ page, offset });
}

function totalPages(html: string) {
  const value = Number(/totalPages\s*:\s*(\d+)/iu.exec(html)?.[1] ?? '1');
  return Number.isSafeInteger(value) && value > 0 ? Math.min(value, 10000) : 1;
}

function categoryForTarget(target: string) {
  const code = /^category:([a-z0-9_-]+)$/iu.exec(target)?.[1];
  const category = categories.find((value) => value.code === code);
  if (category === undefined) throw new Error('Discovery target is invalid.');
  return category;
}

function categoryUrl(code: string, page: number) {
  return base + '/?type=' + encodeURIComponent(code) + '&p=' + page;
}

function searchUrl(query: string, page: number) {
  return base + '/?p=' + page + '&search2=' + searchKey + '&search=' + encodeURIComponent(query);
}

function detailUrl(id: string) {
  return base + '/view/?id=' + encodeURIComponent(id);
}

function chapterId(id: string) {
  return 'video:' + id + ':main';
}

function contentId(id: string) {
  const match = /^video:([a-z0-9_-]+)$/iu.exec(id);
  if (match?.[1] === undefined) throw new Error('Content ID is invalid.');
  return match[1];
}

function safeMediaUrl(value: string) {
  try {
    const url = new URL(value);
    return (url.protocol === 'https:' || url.protocol === 'http:') && url.username === '' && url.password === '';
  } catch {
    return false;
  }
}

function absolute(value: string | null) {
  if (value === null || value === '') return null;
  try {
    return new URL(decode(value).replaceAll('\\/', '/'), base).toString();
  } catch {
    return null;
  }
}

function attribute(text: string, name: string) {
  return new RegExp(escape(name) + "\\s*=\\s*[\"']([^\"']+)[\"']", 'iu').exec(text)?.[1] ?? '';
}

function strip(value: string) {
  return decode(value
    .replace(/<script[\s\S]*?<\/script>/giu, '')
    .replace(/<style[\s\S]*?<\/style>/giu, '')
    .replace(/<[^>]+>/gu, ' ')
    .replace(/\s+/gu, ' '))
    .trim();
}

function decode(value: string) {
  return value
    .replace(/&amp;/giu, '&')
    .replace(/&quot;/giu, '"')
    .replace(/&#39;/giu, "'")
    .replace(/&lt;/giu, '<')
    .replace(/&gt;/giu, '>')
    .replace(/&nbsp;/giu, ' ');
}

function clamp(value: number) {
  return Math.max(1, Math.min(100, Math.floor(value)));
}

function frozen<T>(value: T): T {
  return Object.freeze(value);
}

function escape(value: string) {
  return value.replace(/[\\^$.*+?()[\]{}|]/gu, '\\$&');
}

function requireContext(): Context {
  if (context === undefined) throw new Error('Source is not activated.');
  return context;
}
