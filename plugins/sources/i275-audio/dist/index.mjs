/**
 * 275听书网原生数据源。
 *
 * 职责：直接解析 i275 移动站的首页、检索、详情、目录和音频地址。
 * 生命周期：activate 注入 Runtime 上下文；宿主 browser.sessionV1 负责复用站点会话。
 * IO：HTML 走宿主会话 HTTP（Node testkit 无会话时回退 ctx.http），封面与音频经 ctx.resource.proxy。
 * 稳定标识：有声书和章节使用 /book/、/play/ 路径中的数字 ID。
 */
import { load } from 'cheerio';
const base = 'https://m.i275.com';
const ua = 'Mozilla/5.0 (Linux; Android 11; Pixel 5) AppleWebKit/537.36 Chrome/90.0.4430.91 Mobile Safari/537.36';
const sessionKey = 'i275-public';
let context;
export async function activate(next) {
    context = next;
    next.log.info('source_activated');
}
export async function search(request) {
    const query = request.query.trim();
    if (query === '')
        return frozen({ items: [], nextCursor: null, totalCount: 0 });
    const page = cursorPage(request.cursor, 'search');
    const limit = clamp(request.pageSize);
    const values = parseBooks(await fetchText(`${base}/search.php?q=${encodeURIComponent(query)}&page=${page}`)).slice(0, limit);
    return frozen({ items: values, nextCursor: values.length >= limit ? `search:${page + 1}` : null, totalCount: null });
}
export async function searchSuggestions(_request) {
    return frozen({ items: [], nextCursor: null });
}
export async function discover(request) {
    if (request.target === null) {
        if (request.cursor !== null || request.collectionId !== null)
            throw new Error('Initial discovery request is invalid.');
        const values = parseBooks(await fetchText(`${base}/`)).slice(0, clamp(request.pageSize));
        const items = values.map((content) => frozen({ content, rank: null, metric: null, recommendation: null }));
        return frozen({
            kind: 'document',
            document: {
                components: [{
                        type: 'section',
                        id: 'audio-home',
                        title: '有声小说',
                        subtitle: null,
                        icon: 'audio',
                        children: [{ type: 'contentCollection', id: 'audio-home-list', layout: 'coverGrid', items, continuation: null }],
                    }],
            },
        });
    }
    throw new Error('Discovery target is invalid.');
}
export async function getDetail(request) {
    const id = contentId(request.id);
    const url = bookUrl(id);
    const $ = load(await fetchText(url));
    const title = clean($('h1.text-2xl').first().text()) || clean($('title').first().text()).replace(/\s*-\s*.*$/u, '');
    const cover = $('.bg-white .w-32 img,.bg-white .w-48 img,img[alt]').first().attr('src') ?? '';
    const description = clean($('.line-clamp-3').first().text());
    const meta = $('.mt-2 p').toArray().map((node) => clean($(node).text()));
    const status = meta.find((value) => value.startsWith('状态：'))?.slice(3).trim() ?? '';
    const chapters = parseChapters($, id);
    const item = summary(id, title, cover, description);
    return frozen({
        ...item,
        status: status.includes('完结') ? 'completed' : 'unknown',
        chapterCount: chapters.length || null,
        latestChapter: chapters.length === 0 ? null : {
            id: chapters.at(-1)?.id ?? null,
            title: chapters.at(-1)?.title ?? '',
            url: null,
            updatedAt: null,
        },
        aliases: [],
        catalogUrl: url,
    });
}
export async function getChapters(request) {
    const id = contentId(request.id);
    const $ = load(await fetchText(bookUrl(id)));
    const items = parseChapters($, id);
    if (items.length === 0)
        throw new Error('No audio chapters found.');
    return frozen({ items, groups: [frozen({ id: `group:${id}:default`, title: '默认线路', order: 0, episodes: items })] });
}
export async function getContent(request) {
    const id = contentId(request.id);
    const chapter = parseChapterId(request.chapterId, id);
    const page = chapterUrl(id, chapter);
    const pageResponse = await fetchPage(page, page);
    const $ = load(pageResponse.body);
    const candidate = audioFromHtml(pageResponse.body)
        || $('audio source,audio').first().attr('src')
        || $('audio[data-src]').first().attr('data-src')
        || $('audio[data-url]').first().attr('data-url')
        || '';
    const upstream = absolute(candidate);
    if (upstream === null || !isAudio(upstream)) {
        requireContext().errors.raise({ code: 'source_media_resolution_failed', message: '音频地址不可用。' });
        throw new Error('Audio address is unavailable.');
    }
    const mediaHeaders = {
        Origin: base,
        Referer: page,
        'User-Agent': pageResponse.sessionUserAgent ?? ua,
    };
    return frozen({
        chapterId: request.chapterId,
        contentKind: 'audio',
        title: null,
        updatedAt: null,
        text: null,
        pages: [],
        media: {
            url: requireContext().resource.proxy({ kind: 'audio', url: upstream, headers: mediaHeaders }),
            resourceType: 'audio',
            resourcePolicy: 'sessionOnly',
            expiresAt: null,
            mimeType: mime(upstream),
            headers: mediaHeaders,
        },
    });
}
async function fetchText(url, referer = `${base}/`) {
    return (await fetchPage(url, referer)).body;
}
async function fetchPage(url, referer) {
    const current = requireContext();
    const sessionRequest = current.browser?.sessionV1?.request;
    if (typeof sessionRequest === 'function') {
        const raw = await sessionRequest.call(current.browser.sessionV1, {
            version: 1,
            sessionKey,
            url,
            method: 'GET',
            headers: { Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8', Referer: referer },
            body: null,
            interaction: 'silent',
            presentation: 'hidden',
            transport: 'http',
            timeoutMs: 30_000,
            maxResponseBytes: 2 * 1024 * 1024,
        });
        const status = raw.status;
        if (typeof raw.body !== 'string' || typeof status !== 'number' || !Number.isInteger(status) || status < 200 || status >= 300) {
            throw new Error('Source request failed.');
        }
        return raw;
    }
    const response = await current.http.fetch(url, {
        headers: {
            Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            Origin: base,
            Referer: referer,
            'User-Agent': ua,
        },
    });
    if (!response.ok)
        throw new Error('Source request failed.');
    return { body: await response.text(), status: response.status, sessionUserAgent: ua };
}
function parseBooks(html) {
    const $ = load(html);
    const values = new Map();
    $('a[href^="/book/"]').each((_, node) => {
        const href = $(node).attr('href') ?? '';
        const id = /\/book\/(\d+)\.html/u.exec(href)?.[1];
        if (id === undefined || values.has(id))
            return;
        const title = clean($(node).find('h3,.font-medium.text-sm,.font-medium').first().text()) || clean($(node).find('img').first().attr('alt') ?? '');
        const cover = $(node).find('img').first().attr('src') ?? '';
        const description = clean($(node).find('.line-clamp-2').first().text());
        if (title !== '')
            values.set(id, summary(id, title, cover, description));
    });
    return [...values.values()];
}
function parseChapters($, book) {
    const values = [];
    const seen = new Set();
    $(`a[href^="/play/${book}/"]`).each((_, node) => {
        const href = $(node).attr('href') ?? '';
        const match = new RegExp(`/play/${book}/(\\d+)\\.html`, 'u').exec(href);
        const title = clean($(node).find('.text-sm.text-gray-700').first().text()) || clean($(node).text());
        if (!match?.[1] || title === '' || seen.has(match[1]))
            return;
        seen.add(match[1]);
        values.push({ id: match[1], title });
    });
    return values.map((value, index) => frozen({
        id: `audio:${book}:${value.id}`,
        title: value.title,
        order: index,
        url: chapterUrl(book, value.id),
        volumeTitle: '默认线路',
        wordCount: null,
        updatedAt: null,
        isLocked: null,
        attributes: [],
    }));
}
function summary(id, title, cover, description) {
    return frozen({
        id: `audio:${id}`,
        title,
        contentKind: 'audio',
        coverOrientation: 'portrait',
        author: null,
        url: bookUrl(id),
        coverUrl: proxyImage(cover),
        description: description || null,
        language: 'zh-CN',
        status: 'unknown',
        access: 'free',
        wordCount: null,
        chapterCount: null,
        publishedAt: null,
        updatedAt: null,
        latestChapter: null,
        categories: ['有声小说'],
        tags: [],
        attributes: [],
    });
}
function audioFromHtml(html) {
    const patterns = [
        /url\s*:\s*["']([^"']+\.(?:mp3|m4a|aac|flac|wav|ogg|opus|ape|wma)(?:\?[^"']*)?)["']/iu,
        /audio_url\s*[=:]\s*["']([^"']+)["']/iu,
        /file\s*[=:]\s*["']([^"']+)["']/iu,
        /(https?:\/\/[^"'<>\\\s]+\.(?:mp3|m4a|aac|flac|wav|ogg|opus|ape|wma)(?:\?[^"'<>\\\s]*)?)/iu,
    ];
    for (const pattern of patterns) {
        const value = pattern.exec(html)?.[1];
        if (value)
            return value.replaceAll('\\/', '/').replaceAll('\\u0026', '&').replaceAll('\\x26', '&').replaceAll('&amp;', '&');
    }
    return '';
}
function bookUrl(id) { return `${base}/book/${id}.html`; }
function chapterUrl(book, chapter) { return `${base}/play/${book}/${chapter}.html`; }
function contentId(id) {
    const value = /^audio:(\d+)$/u.exec(id)?.[1];
    if (value === undefined)
        throw new Error('Content ID is invalid.');
    return value;
}
function parseChapterId(id, book) {
    const value = new RegExp(`^audio:${book}:(\\d+)$`, 'u').exec(id)?.[1];
    if (value === undefined)
        throw new Error('Chapter ID is invalid.');
    return value;
}
function proxyImage(value) {
    const url = absolute(value);
    return url === null ? null : requireContext().resource.proxy({ kind: 'image', url, headers: { Referer: `${base}/` } });
}
function absolute(value) {
    const raw = value.trim();
    if (raw === '')
        return null;
    try {
        return new URL(raw.replaceAll('\\/', '/'), base).toString();
    }
    catch {
        return null;
    }
}
function isAudio(url) { return /\.(?:mp3|m4a|aac|flac|wav|ogg|opus|ape|wma)(?:$|[?#])/iu.test(url); }
function mime(url) {
    if (/\.m4a(?:$|[?#])/iu.test(url))
        return 'audio/mp4';
    if (/\.aac(?:$|[?#])/iu.test(url))
        return 'audio/aac';
    if (/\.flac(?:$|[?#])/iu.test(url))
        return 'audio/flac';
    return 'audio/mpeg';
}
function clean(value) { return value.replace(/\s+/gu, ' ').trim(); }
function cursorPage(cursor, target) {
    if (cursor === null)
        return 1;
    const raw = cursor.startsWith(`${target}:`) ? cursor.slice(target.length + 1) : '';
    const page = Number(raw);
    if (!Number.isSafeInteger(page) || page < 2 || page > 1000)
        throw new Error('Cursor is invalid.');
    return page;
}
function clamp(value) { return Math.max(1, Math.min(50, Math.floor(value))); }
function frozen(value) { return Object.freeze(value); }
function requireContext() { if (context === undefined)
    throw new Error('Source is not activated.'); return context; }
