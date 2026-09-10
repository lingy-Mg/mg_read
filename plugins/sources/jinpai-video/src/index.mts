/**
 * 金牌影院 WebView 数据源。
 *
 * 职责：在站点要求的浏览器会话中读取分类、搜索、详情、选集与播放地址。
 * 生命周期：activate 仅保存公开上下文；所有操作串行复用宿主持有的单个页面，以保留人工验证后的 Cookie。
 * IO：只通过 ctx.webview 访问受保护页面；封面与 HLS 只登记给 ctx.resource.proxy。
 * 安全验证：检测到验证页时显示同一 WebView 并返回 source_access_blocked，用户完成验证后重试原操作。
 * 稳定标识：作品、线路和选集采用站内 vod 路径中的不透明标识，不含 Cookie 或验证令牌。
 */
import type { MgReadPluginContext, PluginJsonValue, PluginWebViewPage } from '@mgread/source-api';

type Context = MgReadPluginContext;
type JsonObject = Record<string, PluginJsonValue>;
type Listing = { readonly id: string; readonly title: string; readonly cover: string; readonly latest: string };
type Detail = Listing & { readonly description: string; readonly author: string; readonly updatedAt: string };
type Episode = { readonly line: string; readonly episode: string; readonly title: string; readonly group: string };

const base = 'https://www.vv3nwjk.com';
const userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36';
const categories = Object.freeze([
  ['movie', '电影', '1'], ['series', '连续剧', '2'], ['variety', '综艺', '3'], ['anime', '动漫', '4'],
] as const);
let context: Context | undefined;
let pageQueue: Promise<void> = Promise.resolve();

export async function activate(next: Context): Promise<void> {
  context = next;
  pageQueue = Promise.resolve();
  next.log.info('source_activated');
}

export async function search(request: { readonly query: string; readonly cursor: string | null; readonly pageSize: number }) {
  const query = clean(request.query);
  if (query === '') return frozen({ items: [], nextCursor: null, totalCount: 0 });
  const pageNumber = cursorPage(request.cursor, 'search');
  const listings = await withPage(async (page) => {
    await requireAccessible(page, `${base}/vodsearch/${encodeURIComponent(query)}----------${pageNumber}---.html`);
    return readListings(page);
  });
  const items = listings.slice(0, clamp(request.pageSize)).map(summary);
  return frozen({ items, nextCursor: listings.length >= items.length && pageNumber < 50 ? `search:${pageNumber + 1}` : null, totalCount: null });
}

export async function searchSuggestions(_request: { readonly cursor: string | null; readonly pageSize: number }) {
  return frozen({ items: [], nextCursor: null });
}

export async function discover(request: { readonly target: string | null; readonly cursor: string | null; readonly collectionId: string | null; readonly pageSize: number }) {
  if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null) throw new Error('Initial discovery request is invalid.');
    return frozen({
      kind: 'document' as const,
      document: { components: [{
        type: 'section', id: 'jinpai-categories', title: '影视分类', subtitle: '金牌影院', icon: 'video',
        children: [{ type: 'categoryCollection', id: 'jinpai-category-list', layout: 'chips', categories: categories.map(([id, title]) => ({ id, title, target: `category:${id}`, count: null, url: null, icon: 'video' })) }],
      }] },
    });
  }
  const category = categories.find(([id]) => request.target === `category:${id}`);
  if (category === undefined) throw new Error('Discovery target is invalid.');
  const pageNumber = cursorPage(request.cursor, request.target);
  const listings = await withPage(async (page) => {
    await requireAccessible(page, `${base}/vodshow/${category[2]}--------${pageNumber}---.html`);
    return readListings(page);
  });
  const contents = listings.slice(0, clamp(request.pageSize)).map(summary);
  const collectionId = `jinpai:${category[0]}`;
  const items = contents.map((content) => frozen({ content, rank: null, metric: null, recommendation: null }));
  const continuation = listings.length >= contents.length && pageNumber < 50 ? frozen({ target: request.target, cursor: `${request.target}:${pageNumber + 1}` }) : null;
  if (request.collectionId !== null) {
    if (request.collectionId !== collectionId) throw new Error('Discovery collection is invalid.');
    return frozen({ kind: 'append' as const, collectionId, items, continuation });
  }
  return frozen({
    kind: 'document' as const,
    document: { components: [{ type: 'section', id: `${collectionId}:section`, title: category[1], subtitle: null, icon: 'video', children: [{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation }] }], },
  });
}

export async function getDetail(request: { readonly id: string }) {
  const id = contentId(request.id);
  const detail = await withPage(async (page) => {
    await requireAccessible(page, detailUrl(id));
    return readDetail(page, id);
  });
  const item = summary(detail);
  return frozen({ ...item, author: detail.author || null, description: detail.description || null, updatedAt: detail.updatedAt || null, aliases: [], catalogUrl: detailUrl(id) });
}

export async function getChapters(request: { readonly id: string }) {
  const id = contentId(request.id);
  const episodes = await withPage(async (page) => {
    await requireAccessible(page, detailUrl(id));
    return readEpisodes(page, id);
  });
  if (episodes.length === 0) throw new Error('No playable episodes found.');
  const rows = episodes.map((episode, order) => frozen({ id: `jinpai:${id}:${episode.line}:${episode.episode}`, title: episode.title, order, url: playUrl(id, episode.line, episode.episode), volumeTitle: episode.group || null, wordCount: null, updatedAt: null, isLocked: null, attributes: [] }));
  const byLine = new Map<string, typeof rows>();
  for (const row of rows) byLine.set(row.id.split(':')[2] ?? '', [...(byLine.get(row.id.split(':')[2] ?? '') ?? []), row]);
  const groups = [...byLine.values()].map((group, order) => frozen({ id: `group:${id}:${order}`, title: group[0]?.volumeTitle ?? `线路 ${order + 1}`, order, episodes: group }));
  return frozen({ items: rows, groups });
}

export async function getContent(request: { readonly id: string; readonly chapterId: string }) {
  const id = contentId(request.id);
  const chapter = parseChapterId(request.chapterId, id);
  const url = playUrl(id, chapter.line, chapter.episode);
  const upstream = await withPage(async (page) => {
    await requireAccessible(page, url);
    const value = await page.executeJavaScript<PluginJsonValue>(`(async()=>{
      for(let attempt=0;attempt<40;attempt+=1){
        const timed=performance.getEntriesByType('resource').map(entry=>entry.name).filter(url=>/^https?:/i.test(url)&&/\\.m3u8(?:[?#]|$)/i.test(url));
        const media=Array.from(document.querySelectorAll('video,audio')).map(node=>node.currentSrc||node.src||'').find(url=>/^https?:/i.test(url)&&/\\.m3u8(?:[?#]|$)/i.test(url));
        const html=String(document.documentElement?.innerHTML||'');
        const embedded=html.match(/https?:[^"'\\\\\s]+?\\.m3u8(?:[^"'\\\\\s]*)/i)?.[0]||'';
        if(timed.length)return timed[timed.length-1]||'';
        if(media)return media;
        if(embedded)return embedded.replaceAll('\\\\/','/');
        await new Promise(resolve=>setTimeout(resolve,500));
      }
      return '';
    })()`, { timeoutMs: 25_000 });
    return typeof value === 'string' ? safeUrl(value) : '';
  });
  if (upstream === '') throw new Error('Playback address is unavailable.');
  const headers = { Referer: url, 'User-Agent': userAgent };
  return frozen({
    chapterId: request.chapterId, contentKind: 'video' as const, title: null, updatedAt: null, text: null, pages: [],
    media: { url: requireContext().resource.proxy({ kind: 'hls', url: upstream, headers }), resourceType: 'hls' as const, resourcePolicy: 'sessionOnly' as const, expiresAt: null, mimeType: 'application/vnd.apple.mpegurl', headers },
  });
}

async function requireAccessible(page: PluginWebViewPage, url: string): Promise<void> {
  await page.navigate(url, { timeoutMs: 35_000 });
  const state = await page.executeJavaScript<PluginJsonValue>(`(()=>({title:document.title||'',text:(document.body?.innerText||'').slice(0,4000),captcha:!!document.querySelector('#grecaptcha,[name="g-recaptcha-response"],iframe[src*="recaptcha"]')}))()`, { timeoutMs: 10_000 });
  if (isRecord(state) && (state.captcha === true || /安全验证|浏览器安全检查|recaptcha/iu.test(`${text(state.title)} ${text(state.text)}`))) {
    await page.show({ timeoutMs: 10_000 });
    requireContext().errors.raise({
      code: 'source_access_blocked',
      message: '金牌影院需要安全验证。已打开验证页面，请手动完成验证后返回并重试；验证 Cookie 会保留在此数据源的 WebView 会话中。',
    });
  }
  await page.hide({ timeoutMs: 10_000 });
}

async function readListings(page: PluginWebViewPage): Promise<Listing[]> {
  const raw = await page.executeJavaScript<PluginJsonValue>(`(()=>Array.from(document.querySelectorAll('a[href*="voddetail"]')).map(anchor=>{
    const href=anchor.href||'';const match=href.match(/\\/voddetail\\/([^/.?#]+)(?:\\.html)?/i);if(!match)return null;
    const image=anchor.querySelector('img');const title=(anchor.getAttribute('title')||anchor.querySelector('.title,.vodlist_title,.module-item-title')?.textContent||image?.getAttribute('alt')||'').replace(/\\s+/g,' ').trim();
    const cover=image?(image.getAttribute('data-original')||image.getAttribute('data-src')||image.currentSrc||image.src||''):'';
    const latest=(anchor.querySelector('.remarks,.note,.pic-text,.module-item-note')?.textContent||'').replace(/\\s+/g,' ').trim();
    return title?{id:match[1],title,cover,latest}:null;
  }).filter(Boolean))()`, { timeoutMs: 15_000 });
  return array(raw).flatMap(projectListing);
}

async function readDetail(page: PluginWebViewPage, id: string): Promise<Detail> {
  const raw = await page.executeJavaScript<PluginJsonValue>(`(()=>{
    const field=(labels)=>{for(const node of document.querySelectorAll('.data,.vod_content,.module-info-item,.module-info-item-content')){const value=(node.textContent||'').replace(/\\s+/g,' ').trim();if(labels.some(label=>value.includes(label)))return value.replace(new RegExp('^.*?(?:'+labels.join('|')+')[：:]?\\\\s*'),'').trim()}return''};
    const image=document.querySelector('.vod_thumb img,.module-item-pic img,.detail-pic img,.poster img');
    return {title:(document.querySelector('h1,.vod-title,.page-title')?.textContent||document.querySelector('meta[property="og:title"]')?.content||'').replace(/\\s+/g,' ').trim(),cover:image?(image.getAttribute('data-original')||image.getAttribute('data-src')||image.currentSrc||image.src||''):'',latest:field(['更新','备注']),author:field(['主演','导演']),updatedAt:field(['年份','上映','更新']),description:(document.querySelector('.vod_content,.module-info-introduction-content,.detail-content,.intro')?.textContent||'').replace(/\\s+/g,' ').trim()};
  })()`, { timeoutMs: 15_000 });
  if (!isRecord(raw)) throw new Error('Video detail is unavailable.');
  const title = clean(text(raw.title));
  if (title === '') throw new Error('Video detail is unavailable.');
  return { id, title, cover: safeUrl(text(raw.cover)), latest: clean(text(raw.latest)), author: clean(text(raw.author)), updatedAt: clean(text(raw.updatedAt)), description: clean(text(raw.description)) };
}

async function readEpisodes(page: PluginWebViewPage, id: string): Promise<Episode[]> {
  const raw = await page.executeJavaScript<PluginJsonValue>(`(()=>Array.from(document.querySelectorAll('a[href*="vodplay"]')).map(anchor=>{
    const href=anchor.href||'';const match=href.match(/\\/vodplay\\/([^/.?#]+?)---(\\d+)---(\\d+)(?:\\.html)?/i);if(!match||match[1]!==${JSON.stringify(id)})return null;
    const list=anchor.closest('.play-list,.module-play-list,.anthology-list,.stui-content__playlist');
    const group=(list?.previousElementSibling?.textContent||list?.parentElement?.querySelector('.title,.module-tab-item.active')?.textContent||'').replace(/\\s+/g,' ').trim();
    const title=(anchor.textContent||anchor.getAttribute('title')||'').replace(/\\s+/g,' ').trim();return title?{line:match[2],episode:match[3],title,group}:null;
  }).filter(Boolean))()`, { timeoutMs: 15_000 });
  return array(raw).flatMap((value) => {
    if (!isRecord(value)) return [];
    const line = text(value.line); const episode = text(value.episode); const title = clean(text(value.title));
    return /^\d+$/u.test(line) && /^\d+$/u.test(episode) && title !== '' ? [{ line, episode, title, group: clean(text(value.group)) }] : [];
  });
}

function withPage<T>(action: (page: PluginWebViewPage) => Promise<T>): Promise<T> {
  const run = pageQueue.then(async () => action(await requireContext().webview.open({ visible: false, timeoutMs: 30_000 })));
  pageQueue = run.then(() => undefined, () => undefined);
  return run;
}
function summary(value: Listing) { return frozen({ id: `video:${encode(value.id)}`, title: value.title, contentKind: 'video' as const, coverOrientation: 'portrait' as const, author: null, url: detailUrl(value.id), coverUrl: proxyImage(value.cover), description: null, language: 'zh-CN', status: 'unknown' as const, access: 'unknown' as const, wordCount: null, chapterCount: null, publishedAt: null, updatedAt: null, latestChapter: value.latest === '' ? null : { id: null, title: value.latest, url: null, updatedAt: null }, categories: [], tags: [], attributes: [] }); }
function proxyImage(value: string): string | null { const url = safeUrl(value); return url === '' ? null : requireContext().resource.proxy({ kind: 'image', url, headers: { Referer: `${base}/` } }); }
function detailUrl(id: string): string { return `${base}/voddetail/${encodeURIComponent(id)}.html`; }
function playUrl(id: string, line: string, episode: string): string { return `${base}/vodplay/${encodeURIComponent(id)}---${line}---${episode}.html`; }
function contentId(value: string): string { const encoded = /^video:([A-Za-z0-9_-]+)$/u.exec(value)?.[1]; const id = encoded === undefined ? '' : decode(encoded); if (!/^[^/?#]+$/u.test(id)) throw new Error('Content ID is invalid.'); return id; }
function parseChapterId(value: string, id: string) { const match = new RegExp(`^jinpai:${escapeRegex(id)}:(\\d+):(\\d+)$`, 'u').exec(value); if (match?.[1] === undefined || match[2] === undefined) throw new Error('Chapter ID is invalid.'); return { line: match[1], episode: match[2] }; }
function cursorPage(cursor: string | null, scope: string): number { if (cursor === null) return 1; const page = Number(cursor.startsWith(`${scope}:`) ? cursor.slice(scope.length + 1) : ''); if (!Number.isSafeInteger(page) || page < 2 || page > 50) throw new Error('Cursor is invalid.'); return page; }
function encode(value: string): string { return Buffer.from(value).toString('base64url'); }
function decode(value: string): string { return Buffer.from(value, 'base64url').toString('utf8'); }
function escapeRegex(value: string): string { return value.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&'); }
function safeUrl(value: string): string { try { const url = new URL(value, base); return /^https?:$/u.test(url.protocol) ? url.toString() : ''; } catch { return ''; } }
function clean(value: string): string { return value.replace(/[\s\u3000\u00a0]+/gu, ' ').trim(); }
function text(value: PluginJsonValue | undefined): string { return typeof value === 'string' || typeof value === 'number' ? String(value) : ''; }
function array(value: PluginJsonValue): readonly PluginJsonValue[] { return Array.isArray(value) ? value : []; }
function isRecord(value: PluginJsonValue): value is JsonObject { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function projectListing(value: PluginJsonValue): Listing[] { if (!isRecord(value)) return []; const id = clean(text(value.id)); const title = clean(text(value.title)); return id !== '' && title !== '' && !/[/?#]/u.test(id) ? [{ id, title, cover: safeUrl(text(value.cover)), latest: clean(text(value.latest)) }] : []; }
function clamp(value: number): number { return Math.max(1, Math.min(50, Math.floor(value))); }
function frozen<T>(value: T): T { return Object.freeze(value); }
function requireContext(): Context { if (context === undefined) throw new Error('Source is not activated.'); return context; }
