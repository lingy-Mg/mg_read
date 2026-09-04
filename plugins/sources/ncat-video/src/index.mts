/**
 * 网飞猫原生 WebView 数据源。
 *
 * 职责：在站点要求的浏览器环境内读取分类、搜索、详情和选集，并从 Resource Timing 提取真实 HLS。
 * 生命周期：activate 注入 Runtime 上下文；同一插件复用宿主持有的单页，并用队列保护跨导航操作。
 * IO：页面只经 ctx.webview；媒体和封面只登记到 ctx.resource.proxy；不依赖旧浏览器回调或兼容层。
 * 稳定标识：作品、线路与选集均使用站点 URL 中的数字 ID。
 */
import type { MgReadPluginContext, PluginJsonValue, PluginWebViewPage } from '@mgread/source-api';

type Context = MgReadPluginContext;
type Json = Record<string, PluginJsonValue>;
type Listing = { id: string; title: string; cover: string; latest: string };
type Detail = { title: string; cover: string; author: string; latest: string; updatedAt: string; description: string };
type Episode = { line: string; episode: string; title: string; group: string };

const base = 'https://www.ncat21.com';
const coverBase = 'https://vres.bavdxfg.cn';
const userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36';
const categories = Object.freeze([
  ['movie', '电影', '1'], ['series', '连续剧', '2'], ['anime', '动漫', '3'],
  ['variety', '综艺纪录', '4'], ['short-drama', '短剧', '5'],
] as const);
let context: Context | undefined;
let pageQueue: Promise<void> = Promise.resolve();

export async function activate(next: Context): Promise<void> {
  context = next;
  pageQueue = Promise.resolve();
  next.log.info('source_activated');
}

export async function search(request: { query: string; cursor: string | null; pageSize: number }) {
  const query = clean(request.query);
  if (query === '') return frozen({ items: [], nextCursor: null, totalCount: 0 });
  const page = cursorPage(request.cursor, 'search');
  const limit = clamp(request.pageSize);
  const values = await withPage(async (browser) => {
    await browser.navigate(base, { timeoutMs: 30_000 });
    const token = await browser.executeJavaScript<PluginJsonValue>(`document.querySelector('input[name="t"]')?.value||''`, { timeoutMs: 10_000 });
    const searchToken = typeof token === 'string' ? token : '';
    await browser.navigate(`${base}/search?t=${encodeURIComponent(searchToken)}&k=${encodeURIComponent(query)}&page=${page}`, { timeoutMs: 30_000 });
    return readListings(browser, '.search-result-list a.search-result-item');
  });
  const items = values.slice(0, limit).map(summary);
  return frozen({ items, nextCursor: values.length >= limit && page < 50 ? `search:${page + 1}` : null, totalCount: null });
}

export async function searchSuggestions(_request: { cursor: string | null; pageSize: number }) {
  return frozen({ items: [], nextCursor: null });
}

export async function discover(request: { target: string | null; cursor: string | null; collectionId: string | null; pageSize: number }) {
  if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null) throw new Error('Initial discovery request is invalid.');
    return frozen({
      kind: 'document' as const,
      document: { components: [{
        type: 'section', id: 'ncat-categories', title: '影视分类', subtitle: '按栏目浏览网飞猫', icon: 'video',
        children: [{
          type: 'categoryCollection', id: 'ncat-category-list', layout: 'chips',
          categories: categories.map(([id, title]) => ({ id, title, target: `category:${id}`, count: null, url: null, icon: 'video' })),
        }],
      }] },
    });
  }
  const category = categories.find(([id]) => request.target === `category:${id}`);
  if (category === undefined) throw new Error('Discovery target is invalid.');
  const page = cursorPage(request.cursor, request.target);
  const limit = clamp(request.pageSize);
  const values = await withPage(async (browser) => {
    await browser.navigate(`${base}/show/${category[2]}------${page}.html`, { timeoutMs: 35_000 });
    return readListings(browser, `a.v-item[href*='/detail/']`);
  });
  const collectionId = `ncat:${category[0]}`;
  const items = values.slice(0, limit).map((content) => frozen({ content: summary(content), rank: null, metric: null, recommendation: null }));
  const continuation = values.length >= limit && page < 50 ? frozen({ target: request.target, cursor: `${request.target}:${page + 1}` }) : null;
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
  const value = await withPage(async (browser) => {
    await browser.navigate(detailUrl(id), { timeoutMs: 35_000 });
    return readDetail(browser);
  });
  const item = summary({ id, title: value.title, cover: value.cover, latest: value.latest });
  return frozen({
    ...item, author: value.author || null, description: value.description || null, updatedAt: value.updatedAt || null,
    aliases: [], catalogUrl: detailUrl(id),
  });
}

export async function getChapters(request: { id: string }) {
  const id = contentId(request.id);
  const episodes = await withPage(async (browser) => {
    await browser.navigate(detailUrl(id), { timeoutMs: 35_000 });
    return readEpisodes(browser, id);
  });
  if (episodes.length === 0) throw new Error('No playable episodes found.');
  const grouped = new Map<string, Episode[]>();
  for (const episode of episodes) grouped.set(episode.line, [...(grouped.get(episode.line) ?? []), episode]);
  const groups = [...grouped.entries()].map(([line, rows], groupOrder) => {
    const title = rows[0]?.group || `线路 ${groupOrder + 1}`;
    const projected = rows.map((episode, order) => frozen({
      id: `ncat:${id}:${line}:${episode.episode}`, title: episode.title, order, url: playUrl(id, line, episode.episode),
      volumeTitle: title, wordCount: null, updatedAt: null, isLocked: null, attributes: [],
    }));
    return frozen({ id: `group:${id}:${line}`, title, order: groupOrder, episodes: projected });
  });
  const items = groups.flatMap((group) => group.episodes).map((episode, order) => frozen({ ...episode, order }));
  return frozen({ items, groups });
}

export async function getContent(request: { id: string; chapterId: string }) {
  const id = contentId(request.id);
  const chapter = parseChapterId(request.chapterId, id);
  const pageUrl = playUrl(id, chapter.line, chapter.episode);
  const headers = { Referer: pageUrl, 'User-Agent': userAgent };
  let upstream = '';
  for (let captureAttempt = 0; captureAttempt < 2 && upstream === ''; captureAttempt += 1) {
    const mediaUrl = await withPage(async (browser) => {
      await browser.navigate(pageUrl, { timeoutMs: 35_000 });
      const value = await browser.executeJavaScript<PluginJsonValue>(`(async()=>{
      for(let attempt=0;attempt<40;attempt+=1){
        const urls=performance.getEntriesByType('resource').map(entry=>entry.name).filter(url=>/^https?:/i.test(url)&&/\\.m3u8(?:[?#]|$)/i.test(url));
        if(urls.length){document.querySelectorAll('video,audio').forEach(media=>{try{media.pause()}catch{}});return urls[urls.length-1]||'';}
        const direct=Array.from(document.querySelectorAll('video')).map(media=>media.currentSrc||media.src||'').find(url=>/^https?:/i.test(url)&&/\\.m3u8(?:[?#]|$)/i.test(url));
        if(direct)return direct;
        await new Promise(resolve=>setTimeout(resolve,500));
      }
      return '';
    })()`, { timeoutMs: 25_000 });
      return typeof value === 'string' ? value : '';
    });
    const candidate = safeUrl(mediaUrl);
    if (candidate !== '' && await probePlaylist(candidate, headers)) upstream = candidate;
  }
  if (upstream === '') throw new Error('Playback address is unavailable.');
  return frozen({
    chapterId: request.chapterId, contentKind: 'video' as const, title: null, updatedAt: null, text: null, pages: [],
    media: {
      url: requireContext().resource.proxy({ kind: 'hls', url: upstream, headers }),
      resourceType: 'hls' as const, resourcePolicy: 'sessionOnly' as const, expiresAt: null,
      mimeType: 'application/vnd.apple.mpegurl', headers,
    },
  });
}

async function probePlaylist(url: string, headers: Record<string, string>): Promise<boolean> {
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      const response = await requireContext().http.fetch(url, { headers, signal: AbortSignal.timeout(15_000) });
      if (response.ok && (await response.text()).trimStart().startsWith('#EXTM3U')) return true;
    } catch { /* retry an intermittently unavailable CDN edge */ }
  }
  return false;
}

async function readListings(browser: PluginWebViewPage, selector: string): Promise<Listing[]> {
  const raw = await browser.executeJavaScript<PluginJsonValue>(`(()=>Array.from(document.querySelectorAll(${JSON.stringify(selector)})).map(anchor=>{
    const href=anchor.href||'';
    const match=href.match(/\\/detail\\/(\\d+)\\.html/);
    const titleNodes=Array.from(anchor.querySelectorAll('.v-item-title,.title'));
    const title=(titleNodes.find(node=>getComputedStyle(node).display!=='none'&&node.textContent.trim())?.textContent||anchor.getAttribute('title')||'').trim();
    const image=Array.from(anchor.querySelectorAll('img')).find(node=>node.id!=='noneCoverImg');
    const cover=image?(image.getAttribute('data-original')||image.getAttribute('data-src')||image.src||''):'';
    const latest=(anchor.querySelector('.v-item-bottom span,.note,.remarks')?.textContent||'').trim();
    return match&&title?{id:match[1],title,cover,latest}:null;
  }).filter(Boolean))()`, { timeoutMs: 15_000 });
  return array(raw).flatMap((value) => projectListing(value));
}

async function readDetail(browser: PluginWebViewPage): Promise<Detail> {
  const raw = await browser.executeJavaScript<PluginJsonValue>(`(()=>{
    const rowValue=(labels)=>{for(const row of document.querySelectorAll('.detail-info-row')){const side=row.querySelector('.detail-info-row-side')?.textContent||'';if(labels.some(label=>side.includes(label)))return(row.querySelector('.detail-info-row-main')?.textContent||'').trim()}return''};
    const image=document.querySelector('.detail-box-side img');
    return{title:(document.querySelector('.detail-title')?.textContent||'').trim(),cover:image?(image.getAttribute('data-original')||image.getAttribute('data-src')||image.src||''):'',author:rowValue(['导演','主演','作者']),latest:rowValue(['备注']),updatedAt:rowValue(['首映']),description:(document.querySelector('.detail-desc,.detail-intro,.detail-content')?.textContent||'').trim()};
  })()`, { timeoutMs: 15_000 });
  if (!isRecord(raw)) throw new Error('Video detail is unavailable.');
  const value = {
    title: clean(text(raw.title)), cover: normalizeCover(text(raw.cover)), author: clean(text(raw.author)),
    latest: clean(text(raw.latest)), updatedAt: clean(text(raw.updatedAt)), description: clean(text(raw.description)),
  };
  if (value.title === '') throw new Error('Video detail is unavailable.');
  return value;
}

async function readEpisodes(browser: PluginWebViewPage, book: string): Promise<Episode[]> {
  const raw = await browser.executeJavaScript<PluginJsonValue>(`(()=>{
    const box=document.querySelector('.episode-list-box-main');if(!box)return[];
    const tabs=[...document.querySelectorAll('.detail-play-box .source-list-box-main .source-item,.source-list-box .source-item,.episode-list-box-source a,.episode-list-box-source span,.episode-list-source-item,.source-tab-item')];
    return Array.from(box.querySelectorAll('.episode-list')).flatMap((list,lineIndex)=>Array.from(list.querySelectorAll('a.episode-item')).map(anchor=>({href:anchor.href,title:(anchor.textContent||'').replace(/\\s+/g,' ').trim(),group:(tabs[lineIndex]?.textContent||('线路 '+(lineIndex+1))).replace(/\\s+/g,' ').trim()})));
  })()`, { timeoutMs: 15_000 });
  return array(raw).flatMap((value) => {
    if (!isRecord(value)) return [];
    const href = text(value.href);
    const match = new RegExp(`/play/${book}-(\\d+)-(\\d+)\\.html`, 'u').exec(href);
    const title = clean(text(value.title));
    if (match?.[1] === undefined || match[2] === undefined || title === '') return [];
    return [{ line: match[1], episode: match[2], title, group: clean(text(value.group)) }];
  });
}

function projectListing(value: PluginJsonValue): Listing[] {
  if (!isRecord(value)) return [];
  const id = text(value.id);
  const title = clean(text(value.title));
  if (!/^\d+$/u.test(id) || title === '') return [];
  return [{ id, title, cover: normalizeCover(text(value.cover)), latest: clean(text(value.latest)) }];
}

function summary(value: Listing) {
  return frozen({
    id: `video:${value.id}`, title: value.title, contentKind: 'video' as const, coverOrientation: 'portrait' as const,
    author: null, url: detailUrl(value.id),
    coverUrl: value.cover === '' ? null : requireContext().resource.proxy({ kind: 'image', url: value.cover, headers: { Referer: `${base}/` } }),
    description: null, language: 'zh-CN', status: 'unknown' as const, access: 'unknown' as const,
    wordCount: null, chapterCount: null, publishedAt: null, updatedAt: null,
    latestChapter: value.latest === '' ? null : { id: null, title: value.latest, url: null, updatedAt: null },
    categories: [], tags: [], attributes: [],
  });
}

function withPage<T>(action: (page: PluginWebViewPage) => Promise<T>): Promise<T> {
  const run = pageQueue.then(async () => action(await requireContext().webview.open({ visible: false, timeoutMs: 30_000 })));
  pageQueue = run.then(() => undefined, () => undefined);
  return run;
}

function contentId(id: string): string { const value = /^video:(\d+)$/u.exec(id)?.[1]; if (value === undefined) throw new Error('Content ID is invalid.'); return value; }
function parseChapterId(id: string, book: string) { const match = new RegExp(`^ncat:${book}:(\\d+):(\\d+)$`, 'u').exec(id); if (match?.[1] === undefined || match[2] === undefined) throw new Error('Chapter ID is invalid.'); return { line: match[1], episode: match[2] }; }
function detailUrl(id: string): string { return `${base}/detail/${id}.html`; }
function playUrl(id: string, line: string, episode: string): string { return `${base}/play/${id}-${line}-${episode}.html`; }
function normalizeCover(value: string): string { if (value === '') return ''; if (/^https?:\/\//iu.test(value)) return safeUrl(value); return safeUrl(`${coverBase}${value.startsWith('/') ? '' : '/'}${value}`); }
function safeUrl(value: string): string { try { const url = new URL(value); return /^https?:$/u.test(url.protocol) ? url.toString() : ''; } catch { return ''; } }
function cursorPage(cursor: string | null, scope: string): number { if (cursor === null) return 1; const raw = cursor.startsWith(`${scope}:`) ? cursor.slice(scope.length + 1) : ''; const page = Number(raw); if (!Number.isSafeInteger(page) || page < 2 || page > 50) throw new Error('Cursor is invalid.'); return page; }
function clean(value: string): string { return value.replace(/[\s\u3000\u00a0]+/gu, ' ').trim(); }
function text(value: PluginJsonValue | undefined): string { return typeof value === 'string' || typeof value === 'number' ? String(value) : ''; }
function array(value: PluginJsonValue): readonly PluginJsonValue[] { return Array.isArray(value) ? value : []; }
function isRecord(value: PluginJsonValue): value is Json { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function clamp(value: number): number { return Math.max(1, Math.min(50, Math.floor(value))); }
function frozen<T>(value: T): T { return Object.freeze(value); }
function requireContext(): Context { if (context === undefined) throw new Error('Source is not activated.'); return context; }
