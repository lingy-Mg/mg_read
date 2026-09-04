const novel = 'https://novel.snssdk.com', web = 'https://fanqienovel.com', book = 'https://fq-book.netsite.cc', contentHosts = ['https://gofq.52dns.cc', 'https://pyfq.52dns.cc', book], headers = { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36', Accept: 'application/json,text/plain,*/*' }, channels = [['1', '都市', 1], ['2', '玄幻', 1], ['3', '仙侠', 1], ['4', '历史', 1], ['5', '科幻', 1], ['6', '游戏', 1], ['22', '古代言情', 2], ['23', '现代言情', 2], ['27', '悬疑推理', 2], ['30', '全本', 1]];
let context;
export async function activate(next) { context = next; next.log.info('source_activated'); }
export async function search(request) { const query = clean(request.query); if (!query)
    return frozen({ items: [], nextCursor: null, totalCount: 0 }); const page = cursorPage(request.cursor, 'search'), offset = (page - 1) * 20, json = await getJson(`${novel}/api/novel/channel/homepage/search/search/v2/?device_platform=android&parent_enterfrom=novel_channel_search.tab.&offset=${offset}&aid=1967&q=${encodeURIComponent(query)}`), data = object(json.data), values = records(data.ret_data).map(summary).filter(notNull).slice(0, clamp(request.pageSize)); return frozen({ items: values, nextCursor: Boolean(data.has_more) && values.length ? `search:${page + 1}` : null, totalCount: null }); }
export async function searchSuggestions(_request) { return frozen({ items: [], nextCursor: null }); }
export async function discover(request) { if (request.target === null)
    return frozen({ kind: 'document', document: { components: [{ type: 'section', id: 'fanqie-channels', title: '番茄小说', subtitle: '公开分类', icon: 'novel', children: [{ type: 'categoryCollection', id: 'fanqie-channel-list', layout: 'chips', categories: channels.map(([id, title]) => ({ id, title, target: `channel:${id}`, count: null, url: null, icon: 'novel' })) }] }] } }); const channel = channels.find(([id]) => request.target === `channel:${id}`); if (!channel)
    throw new Error('Discovery target is invalid.'); const page = cursorPage(request.cursor, request.target), size = clamp(request.pageSize), url = `${novel}/api/novel/channel/homepage/new_category/book_list/v1/?parent_enterfrom=novel_channel_category.tab.&aid=1967&offset=${(page - 1) * size}&limit=${size}&category_id=${channel[0]}&gender=${channel[2]}`, json = await getJson(url), data = object(json.data), values = records(data.data).map(summary).filter(notNull), collectionId = `fanqie:${channel[0]}`, items = values.map(content => frozen({ content, rank: null, metric: null, recommendation: null })), continuation = values.length >= size ? frozen({ target: request.target, cursor: `${request.target}:${page + 1}` }) : null; if (request.collectionId !== null) {
    if (request.collectionId !== collectionId)
        throw new Error('Discovery collection is invalid.');
    return frozen({ kind: 'append', collectionId, items, continuation });
} return frozen({ kind: 'document', document: { components: [{ type: 'section', id: `${collectionId}:section`, title: channel[1], subtitle: null, icon: 'novel', children: [{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation }] }] } }); }
export async function getDetail(request) { const id = contentId(request.id), json = await getJson(`${book}/info?book_id=${id}`), data = findBook(json), item = summary({ ...data, book_id: id }); if (!item)
    throw new Error('Book detail is unavailable.'); return frozen({ ...item, description: text(data.abstract || data.intro) || null, chapterCount: number(data.chapter_number) || null, latestChapter: text(data.last_chapter_title) ? { id: `novel:${id}:latest`, title: text(data.last_chapter_title), url: null, updatedAt: null } : null, aliases: [], catalogUrl: `${web}/api/reader/directory/detail?bookId=${id}` }); }
export async function getChapters(request) { const id = contentId(request.id), json = await getJson(`${web}/api/reader/directory/detail?bookId=${id}`), data = object(json.data), items = []; const volumes = Array.isArray(data.chapterListWithVolume) ? data.chapterListWithVolume : []; for (const [volumeIndex, raw] of volumes.entries())
    for (const chapter of records(raw)) {
        const itemId = text(chapter.itemId);
        if (!/^\d+$/u.test(itemId))
            continue;
        items.push({ id: `novel:${id}:${itemId}`, title: text(chapter.title) || `第${items.length + 1}章`, order: items.length, url: null, volumeTitle: `第${volumeIndex + 1}卷`, wordCount: null, updatedAt: timestamp(chapter.firstPassTime), isLocked: false, attributes: [] });
    } if (!items.length)
    for (const raw of Array.isArray(data.allItemIds) ? data.allItemIds : []) {
        const itemId = text(raw);
        if (/^\d+$/u.test(itemId))
            items.push({ id: `novel:${id}:${itemId}`, title: `第${items.length + 1}章`, order: items.length, url: null, volumeTitle: null, wordCount: null, updatedAt: null, isLocked: false, attributes: [] });
    } const groups = [...new Set(items.map(value => value.volumeTitle).filter((value) => value !== null))].map((title, index) => frozen({ id: `group:${id}:${index}`, title, order: index, episodes: items.filter(item => item.volumeTitle === title) })); return frozen({ items: Object.freeze(items.map(frozen)), groups }); }
export async function getContent(request) { const id = contentId(request.id), itemId = chapterNative(request.chapterId, id); let html = ''; for (const host of contentHosts)
    try {
        const json = await getJson(`${host}/content?item_id=${itemId}`), candidate = findContent(json);
        if (candidate) {
            html = candidate;
            break;
        }
    }
    catch {
        continue;
    } if (!html)
    throw new Error('Chapter content is unavailable.'); const textValue = formatContent(html); if (!textValue)
    throw new Error('Chapter content is empty.'); return frozen({ chapterId: request.chapterId, contentKind: 'novel', title: null, updatedAt: null, text: textValue, pages: [], media: null }); }
async function getJson(url) { const response = await requireContext().http.fetch(url, { headers }); if (!response.ok)
    throw new Error('Source request failed.'); let value; try {
    value = await response.json();
}
catch {
    throw new Error('Source response is invalid.');
} if (!isObject(value))
    throw new Error('Source response is invalid.'); return value; }
function summary(value) { const id = text(value.book_id || value.bookId), title = clean(text(value.book_name || value.title || value.name)); if (!/^\d+$/u.test(id) || !title)
    return null; const rawCover = text(value.thumb_url || value.cover || value.cover_url), cover = replaceCover(rawCover), status = number(value.creation_status) === 1 ? 'completed' : 'ongoing'; return frozen({ id: `novel:${id}`, title, contentKind: 'novel', coverOrientation: 'portrait', author: clean(text(value.author)) || null, url: `${web}/page/${id}`, coverUrl: cover ? requireContext().resource.proxy({ kind: 'image', url: cover, headers: { Referer: `${web}/` } }) : null, description: clean(text(value.abstract || value.book_abstract_v2)) || null, language: 'zh-CN', status, access: 'free', wordCount: number(value.word_number) || null, chapterCount: number(value.chapter_number) || null, publishedAt: null, updatedAt: null, latestChapter: null, categories: text(value.category) ? [text(value.category)] : [], tags: text(value.tags) ? text(value.tags).split(',').map(clean).filter(Boolean) : [], attributes: [] }); }
function replaceCover(value) { if (!safeUrl(value))
    return ''; const url = new URL(value); const path = url.pathname.replace(/~.*$/u, ''); return `https://p6-novel.byteimg.com/origin${path}`; }
function findBook(root) { const queue = [root], seen = new Set(); while (queue.length) {
    const current = queue.shift();
    if (seen.has(current))
        continue;
    seen.add(current);
    if (text(current.book_name || current.name))
        return current;
    for (const value of Object.values(current))
        if (isObject(value))
            queue.push(value);
} return {}; }
function findContent(root) { if (typeof root === 'string')
    return root.includes('<p') ? root : ''; if (Array.isArray(root))
    for (const value of root) {
        const found = findContent(value);
        if (found)
            return found;
    }
else if (isObject(root)) {
    if (typeof root.content === 'string' && root.content)
        return root.content;
    for (const value of Object.values(root)) {
        const found = findContent(value);
        if (found)
            return found;
    }
} return ''; }
function formatContent(value) { const html = value.replace(/##收听有声版[\s\S]*$/u, '').replace(/<tt_keyword_ad[\s\S]*?<\/tt_keyword_ad>/giu, ' '), paragraphs = [...html.matchAll(/<p[^>]*>([\s\S]*?)<\/p>/giu)].map(match => decode(clean(match[1] ?? ''))).filter(Boolean); return (paragraphs.length ? paragraphs : [decode(clean(html))]).filter(Boolean).join('\n\n'); }
function contentId(id) { const value = /^novel:(\d+)$/u.exec(id)?.[1]; if (!value)
    throw new Error('Content ID is invalid.'); return value; }
function chapterNative(id, bookId) { const value = new RegExp(`^novel:${bookId}:(\\d+)$`, 'u').exec(id)?.[1]; if (!value)
    throw new Error('Chapter ID is invalid.'); return value; }
function timestamp(value) { const numberValue = number(value); if (numberValue <= 0)
    return null; return new Date(numberValue * (numberValue < 1e12 ? 1000 : 1)).toISOString(); }
function decode(value) { return value.replaceAll('&nbsp;', ' ').replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&amp;', '&').replaceAll('&quot;', '"').replaceAll('&#39;', "'"); }
function clean(value) { return value.replaceAll(/<[^>]+>/gu, ' ').replaceAll(/\s+/gu, ' ').trim(); }
function object(value) { return isObject(value) ? value : {}; }
function records(value) { return Array.isArray(value) ? value.filter(isObject) : []; }
function isObject(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function number(value) { return typeof value === 'number' && Number.isFinite(value) ? value : typeof value === 'string' ? Number(value) || 0 : 0; }
function text(value) { return typeof value === 'string' ? value.trim() : typeof value === 'number' ? String(value) : ''; }
function safeUrl(value) { try {
    return ['http:', 'https:'].includes(new URL(value).protocol);
}
catch {
    return false;
} }
function notNull(value) { return value !== null; }
function cursorPage(cursor, target) { if (cursor === null)
    return 1; const page = Number(cursor.startsWith(`${target}:`) ? cursor.slice(target.length + 1) : ''); if (!Number.isSafeInteger(page) || page < 2)
    throw new Error('Cursor is invalid.'); return page; }
function clamp(value) { return Math.max(1, Math.min(100, Math.floor(value))); }
function frozen(value) { return Object.freeze(value); }
function requireContext() { if (!context)
    throw new Error('Source is not activated.'); return context; }
