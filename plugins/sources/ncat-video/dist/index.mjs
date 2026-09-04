const base = 'https://www.ncat21.com';
const coverBase = 'https://vres.bavdxfg.cn';
const userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36';
const categories = Object.freeze([
    ['movie', '电影', '1'], ['series', '连续剧', '2'], ['anime', '动漫', '3'],
    ['variety', '综艺纪录', '4'], ['short-drama', '短剧', '5'],
]);
let context;
let pageQueue = Promise.resolve();
export async function activate(next) {
    context = next;
    pageQueue = Promise.resolve();
    next.log.info('source_activated');
}
export async function search(request) {
    const query = clean(request.query);
    if (query === '')
        return frozen({ items: [], nextCursor: null, totalCount: 0 });
    const page = cursorPage(request.cursor, 'search');
    const limit = clamp(request.pageSize);
    const values = await withPage(async (browser) => {
        await browser.navigate(base, { timeoutMs: 30_000 });
        const token = await browser.executeJavaScript(`document.querySelector('input[name="t"]')?.value||''`, { timeoutMs: 10_000 });
        const searchToken = typeof token === 'string' ? token : '';
        await browser.navigate(`${base}/search?t=${encodeURIComponent(searchToken)}&k=${encodeURIComponent(query)}&page=${page}`, { timeoutMs: 30_000 });
        return readListings(browser, '.search-result-list a.search-result-item');
    });
    const items = values.slice(0, limit).map(summary);
    return frozen({ items, nextCursor: values.length >= limit && page < 50 ? `search:${page + 1}` : null, totalCount: null });
}
export async function searchSuggestions(_request) {
    return frozen({ items: [], nextCursor: null });
}
export async function discover(request) {
    if (request.target === null) {
        if (request.cursor !== null || request.collectionId !== null)
            throw new Error('Initial discovery request is invalid.');
        return frozen({
            kind: 'document',
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
    if (category === undefined)
        throw new Error('Discovery target is invalid.');
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
        if (request.collectionId !== collectionId)
            throw new Error('Discovery collection is invalid.');
        return frozen({ kind: 'append', collectionId, items, continuation });
    }
    return frozen({
        kind: 'document',
        document: { components: [{
                    type: 'section', id: `${collectionId}:section`, title: category[1], subtitle: null, icon: 'video',
                    children: [{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation }],
                }] },
    });
}
export async function getDetail(request) {
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
export async function getChapters(request) {
    const id = contentId(request.id);
    const episodes = await withPage(async (browser) => {
        await browser.navigate(detailUrl(id), { timeoutMs: 35_000 });
        return readEpisodes(browser, id);
    });
    if (episodes.length === 0)
        throw new Error('No playable episodes found.');
    const grouped = new Map();
    for (const episode of episodes)
        grouped.set(episode.line, [...(grouped.get(episode.line) ?? []), episode]);
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
export async function getContent(request) {
    const id = contentId(request.id);
    const chapter = parseChapterId(request.chapterId, id);
    const pageUrl = playUrl(id, chapter.line, chapter.episode);
    const headers = { Referer: pageUrl, 'User-Agent': userAgent };
    let upstream = '';
    for (let captureAttempt = 0; captureAttempt < 2 && upstream === ''; captureAttempt += 1) {
        const mediaUrl = await withPage(async (browser) => {
            await browser.navigate(pageUrl, { timeoutMs: 35_000 });
            const value = await browser.executeJavaScript(`(async()=>{
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
        if (candidate !== '' && await probePlaylist(candidate, headers))
            upstream = candidate;
    }
    if (upstream === '')
        throw new Error('Playback address is unavailable.');
    return frozen({
        chapterId: request.chapterId, contentKind: 'video', title: null, updatedAt: null, text: null, pages: [],
        media: {
            url: requireContext().resource.proxy({ kind: 'hls', url: upstream, headers }),
            resourceType: 'hls', resourcePolicy: 'sessionOnly', expiresAt: null,
            mimeType: 'application/vnd.apple.mpegurl', headers,
        },
    });
}
async function probePlaylist(url, headers) {
    for (let attempt = 0; attempt < 2; attempt += 1) {
        try {
            const response = await requireContext().http.fetch(url, { headers, signal: AbortSignal.timeout(15_000) });
            if (response.ok && (await response.text()).trimStart().startsWith('#EXTM3U'))
                return true;
        }
        catch { /* retry an intermittently unavailable CDN edge */ }
    }
    return false;
}
async function readListings(browser, selector) {
    const raw = await browser.executeJavaScript(`(()=>Array.from(document.querySelectorAll(${JSON.stringify(selector)})).map(anchor=>{
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
async function readDetail(browser) {
    const raw = await browser.executeJavaScript(`(()=>{
    const rowValue=(labels)=>{for(const row of document.querySelectorAll('.detail-info-row')){const side=row.querySelector('.detail-info-row-side')?.textContent||'';if(labels.some(label=>side.includes(label)))return(row.querySelector('.detail-info-row-main')?.textContent||'').trim()}return''};
    const image=document.querySelector('.detail-box-side img');
    return{title:(document.querySelector('.detail-title')?.textContent||'').trim(),cover:image?(image.getAttribute('data-original')||image.getAttribute('data-src')||image.src||''):'',author:rowValue(['导演','主演','作者']),latest:rowValue(['备注']),updatedAt:rowValue(['首映']),description:(document.querySelector('.detail-desc,.detail-intro,.detail-content')?.textContent||'').trim()};
  })()`, { timeoutMs: 15_000 });
    if (!isRecord(raw))
        throw new Error('Video detail is unavailable.');
    const value = {
        title: clean(text(raw.title)), cover: normalizeCover(text(raw.cover)), author: clean(text(raw.author)),
        latest: clean(text(raw.latest)), updatedAt: clean(text(raw.updatedAt)), description: clean(text(raw.description)),
    };
    if (value.title === '')
        throw new Error('Video detail is unavailable.');
    return value;
}
async function readEpisodes(browser, book) {
    const raw = await browser.executeJavaScript(`(()=>{
    const box=document.querySelector('.episode-list-box-main');if(!box)return[];
    const tabs=[...document.querySelectorAll('.detail-play-box .source-list-box-main .source-item,.source-list-box .source-item,.episode-list-box-source a,.episode-list-box-source span,.episode-list-source-item,.source-tab-item')];
    return Array.from(box.querySelectorAll('.episode-list')).flatMap((list,lineIndex)=>Array.from(list.querySelectorAll('a.episode-item')).map(anchor=>({href:anchor.href,title:(anchor.textContent||'').replace(/\\s+/g,' ').trim(),group:(tabs[lineIndex]?.textContent||('线路 '+(lineIndex+1))).replace(/\\s+/g,' ').trim()})));
  })()`, { timeoutMs: 15_000 });
    return array(raw).flatMap((value) => {
        if (!isRecord(value))
            return [];
        const href = text(value.href);
        const match = new RegExp(`/play/${book}-(\\d+)-(\\d+)\\.html`, 'u').exec(href);
        const title = clean(text(value.title));
        if (match?.[1] === undefined || match[2] === undefined || title === '')
            return [];
        return [{ line: match[1], episode: match[2], title, group: clean(text(value.group)) }];
    });
}
function projectListing(value) {
    if (!isRecord(value))
        return [];
    const id = text(value.id);
    const title = clean(text(value.title));
    if (!/^\d+$/u.test(id) || title === '')
        return [];
    return [{ id, title, cover: normalizeCover(text(value.cover)), latest: clean(text(value.latest)) }];
}
function summary(value) {
    return frozen({
        id: `video:${value.id}`, title: value.title, contentKind: 'video', coverOrientation: 'portrait',
        author: null, url: detailUrl(value.id),
        coverUrl: value.cover === '' ? null : requireContext().resource.proxy({ kind: 'image', url: value.cover, headers: { Referer: `${base}/` } }),
        description: null, language: 'zh-CN', status: 'unknown', access: 'unknown',
        wordCount: null, chapterCount: null, publishedAt: null, updatedAt: null,
        latestChapter: value.latest === '' ? null : { id: null, title: value.latest, url: null, updatedAt: null },
        categories: [], tags: [], attributes: [],
    });
}
function withPage(action) {
    const run = pageQueue.then(async () => action(await requireContext().webview.open({ visible: false, timeoutMs: 30_000 })));
    pageQueue = run.then(() => undefined, () => undefined);
    return run;
}
function contentId(id) { const value = /^video:(\d+)$/u.exec(id)?.[1]; if (value === undefined)
    throw new Error('Content ID is invalid.'); return value; }
function parseChapterId(id, book) { const match = new RegExp(`^ncat:${book}:(\\d+):(\\d+)$`, 'u').exec(id); if (match?.[1] === undefined || match[2] === undefined)
    throw new Error('Chapter ID is invalid.'); return { line: match[1], episode: match[2] }; }
function detailUrl(id) { return `${base}/detail/${id}.html`; }
function playUrl(id, line, episode) { return `${base}/play/${id}-${line}-${episode}.html`; }
function normalizeCover(value) { if (value === '')
    return ''; if (/^https?:\/\//iu.test(value))
    return safeUrl(value); return safeUrl(`${coverBase}${value.startsWith('/') ? '' : '/'}${value}`); }
function safeUrl(value) { try {
    const url = new URL(value);
    return /^https?:$/u.test(url.protocol) ? url.toString() : '';
}
catch {
    return '';
} }
function cursorPage(cursor, scope) { if (cursor === null)
    return 1; const raw = cursor.startsWith(`${scope}:`) ? cursor.slice(scope.length + 1) : ''; const page = Number(raw); if (!Number.isSafeInteger(page) || page < 2 || page > 50)
    throw new Error('Cursor is invalid.'); return page; }
function clean(value) { return value.replace(/[\s\u3000\u00a0]+/gu, ' ').trim(); }
function text(value) { return typeof value === 'string' || typeof value === 'number' ? String(value) : ''; }
function array(value) { return Array.isArray(value) ? value : []; }
function isRecord(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function clamp(value) { return Math.max(1, Math.min(50, Math.floor(value))); }
function frozen(value) { return Object.freeze(value); }
function requireContext() { if (context === undefined)
    throw new Error('Source is not activated.'); return context; }
