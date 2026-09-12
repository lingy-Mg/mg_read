/**
 * 速读谷数据源插件实现。
 *
 * 职责：解析发现、搜索、详情、目录和正文，并复用插件私有的 HTML/投影缓存。
 * 注意：发现页允许过期详情投影立即返回并后台刷新；用户打开详情和目录仍遵守一小时严格新鲜度。
 */
import * as cheerio from 'cheerio/slim';
import { PluginCache } from './html-cache.js';
import { nonBlank } from './utils.js';
// Discovery cards may use a stale projection immediately and refresh it for the
// next visit. Detail and shelf data are deliberately strict: no value older
// than one hour is returned after a failed refresh.
const discoveryListingPolicy = Object.freeze({ namespace: 'listing', staleAfterMs: 60 * 60 * 1000, serveStaleWhileRevalidate: true });
const searchListingPolicy = Object.freeze({ namespace: 'search', staleAfterMs: 10 * 60 * 1000 });
const detailPolicy = Object.freeze({ namespace: 'detail', staleAfterMs: 60 * 60 * 1000, allowStaleOnError: false });
const discoveryDetailPolicy = Object.freeze({ namespace: 'detail', staleAfterMs: 60 * 60 * 1000, serveStaleWhileRevalidate: true });
const detailProjectionPolicy = Object.freeze({ namespace: 'detail-projection-v1', staleAfterMs: 60 * 60 * 1000, allowStaleOnError: false });
const discoveryDetailProjectionPolicy = Object.freeze({ namespace: 'detail-projection-v1', staleAfterMs: 60 * 60 * 1000, serveStaleWhileRevalidate: true });
const hotSearchPolicy = Object.freeze({ namespace: 'hot-search', staleAfterMs: 24 * 60 * 60 * 1000 });
function loadCheerio() { return Promise.resolve(cheerio); }
export class ShuduguSource {
    context;
    #baseUrl;
    #categories;
    #cache;
    #catalogs = new Map();
    #details = new Map();
    #discoveryDetailRequests = new Map();
    #detailRequests = new Map();
    constructor(context, rules) {
        this.context = context;
        this.#baseUrl = new URL(rules.origin);
        if (this.#baseUrl.protocol !== 'https:' || this.#baseUrl.pathname !== '/')
            throw new Error('Source origin is invalid.');
        this.#categories = Object.freeze(rules.categories.map((item) => {
            if (!/^[a-z]+$/.test(item.id) || nonBlank(item.title) === null)
                throw new Error('Source categories are invalid.');
            return Object.freeze({ id: item.id, title: item.title });
        }));
        this.#cache = new PluginCache(context.cacheDir, { logger: context.log });
    }
    async discover(request) {
        if (request.target === null) {
            const home = await this.#loadHomeDiscovery();
            const components = [];
            if (home.latest.length !== 0) {
                components.push(Object.freeze({
                    type: 'section', id: 'shudugu-latest-section', title: '正在热更', subtitle: '来自官网最新更新', icon: 'ongoing',
                    children: Object.freeze([Object.freeze({
                            type: 'contentCollection', id: 'shudugu-latest-books', layout: 'shelf',
                            items: this.#discoveryItems(home.latest), continuation: null,
                        })]),
                }));
            }
            const overviewChildren = [];
            if (home.ranked.length !== 0) {
                overviewChildren.push(Object.freeze({
                    type: 'section', id: 'shudugu-ranking-section', title: '阅读排行', subtitle: '站内热门作品', icon: 'ranking',
                    children: Object.freeze([Object.freeze({
                            type: 'contentCollection', id: 'shudugu-ranking-books', layout: 'compact',
                            items: this.#discoveryItems(home.ranked, true), continuation: null,
                        })]),
                }));
            }
            if (home.completed.length !== 0) {
                overviewChildren.push(Object.freeze({
                    type: 'section', id: 'shudugu-completed-section', title: '完结精选', subtitle: '一次读到结局', icon: 'completed',
                    children: Object.freeze([Object.freeze({
                            type: 'contentCollection', id: 'shudugu-completed-books', layout: 'coverGrid',
                            items: this.#discoveryItems(home.completed), continuation: null,
                        })]),
                }));
            }
            if (overviewChildren.length !== 0) {
                components.push(Object.freeze({
                    type: 'group', id: 'shudugu-overview-group', layout: 'vertical',
                    children: Object.freeze(overviewChildren),
                }));
            }
            components.push(Object.freeze({
                type: 'section', id: 'shudugu-categories-section', title: '探索分类', subtitle: '按题材继续发现', icon: 'explore',
                children: Object.freeze([Object.freeze({
                        type: 'categoryCollection', id: 'shudugu-categories', layout: 'chips', categories: Object.freeze(this.#categories.map((category) => Object.freeze({
                            id: `category:${category.id}`, title: category.title, target: `category:${category.id}`, count: null,
                            icon: categoryIcon(category.id, category.title),
                            url: new URL(`/${category.id}/`, this.#baseUrl).toString(),
                        }))),
                    })]),
            }));
            return Object.freeze({ kind: 'document', document: Object.freeze({ components: Object.freeze(components) }) });
        }
        const category = this.#category(request.target);
        const page = decodePage(request.cursor, 'category-page');
        const url = this.#categoryUrl(category.id, page);
        const books = await this.#parseList(await this.#getHtml(url, discoveryListingPolicy), url);
        const visible = await this.#withDetails(books.slice(0, boundedPageSize(request.pageSize)));
        const collectionId = `category-books:${category.id}`;
        const continuation = books.length >= boundedPageSize(request.pageSize)
            ? Object.freeze({ target: request.target, cursor: `category-page:${page + 1}` }) : null;
        const items = Object.freeze(visible.map((content) => Object.freeze({ content, rank: null, metric: null, recommendation: null })));
        if (request.collectionId !== null) {
            if (request.collectionId !== collectionId || request.cursor === null)
                throw new Error('Discovery continuation is invalid.');
            return Object.freeze({ kind: 'append', collectionId, items, continuation });
        }
        return documentResult(Object.freeze({
            type: 'section', id: `category-section:${category.id}`, title: category.title, subtitle: null,
            children: Object.freeze([Object.freeze({ type: 'contentCollection', id: collectionId, layout: 'list', items, continuation })]),
        }));
    }
    async search(request) {
        const page = decodePage(request.cursor, 'search-page');
        const url = new URL('/i/sor.aspx', this.#baseUrl);
        url.searchParams.set('key', request.query);
        if (page > 1)
            url.searchParams.set('page', String(page));
        const html = await this.#getHtml(url, searchListingPolicy);
        const books = await this.#parseList(html, url);
        const size = boundedPageSize(request.pageSize);
        return Object.freeze({ items: await this.#withDetails(books.slice(0, size)), nextCursor: null, totalCount: parseSearchTotal(html) });
    }
    async searchSuggestions(request) {
        if (decodePage(request.cursor, 'suggestions-page') > 1)
            return Object.freeze({ items: Object.freeze([]), nextCursor: null });
        const url = new URL('/', this.#baseUrl);
        const queries = await this.#parseHotSearches(await this.#getHtml(url, hotSearchPolicy));
        return Object.freeze({ items: Object.freeze(queries.slice(0, boundedPageSize(request.pageSize)).map((query) => Object.freeze({ query, metric: null }))), nextCursor: null });
    }
    async getDetail(request) {
        const cached = this.#details.get(request.id);
        if (cached !== undefined && cached.expiresAtMs >= Date.now())
            return cached.value;
        const inFlight = this.#detailRequests.get(request.id);
        if (inFlight !== undefined)
            return inFlight;
        const pending = this.#loadCachedDetail(request, detailProjectionPolicy, detailPolicy).then((projection) => projection.detail);
        this.#detailRequests.set(request.id, pending);
        void pending.then(() => this.#detailRequests.delete(request.id), () => this.#detailRequests.delete(request.id));
        return pending;
    }
    async #loadDetailProjection(request, cachePolicy) {
        const id = decodeNovelId(request.id);
        const url = new URL(`/${id}/`, this.#baseUrl);
        const cheerio = await loadCheerio();
        const cachedHtml = await this.#getHtmlResult(url, cachePolicy);
        const $ = cheerio.load(cachedHtml.body);
        const item = $('.item').first();
        const title = required(item.find('.itemtxt h1 a, .itemtxt h3 a').first().text());
        const spans = item.find('.itemtxt p span').toArray().map((element) => required($(element).text()));
        const author = textOrNull(item.find('.itemtxt a').filter((_, element) => /^作者[：:]/u.test($(element).text())).first().text().replace(/^作者[：:]/u, ''));
        const category = textOrNull(spans[1]);
        const description = textOrNull($('.des.bb').first().text());
        const wordCount = parseCount(item.find('.itemtxt h1 i').first().text(), '字');
        const status = parseStatus(spans[0]);
        const updatedAt = parseDate($('#dir > span').first().text());
        const latestLink = item.find('ul li a').last();
        const latestTitle = textOrNull(latestLink.text());
        const latestHref = latestLink.attr('href');
        const latestChapter = latestTitle === null || latestHref === undefined ? null : Object.freeze({
            id: this.#chapterId(this.#sourceUrl(latestHref, url)), title: latestTitle,
            url: this.#sourceUrl(latestHref, url).toString(), updatedAt,
        });
        const coverUrl = this.#proxyCoverUrl(item.find('img').first().attr('src'), url);
        const chapters = await this.#loadCatalog(cheerio, cachedHtml.body, url, id, cachePolicy);
        const detail = Object.freeze({
            ...this.#summary({ id, title, author, category, coverUrl, description, status, wordCount,
                chapterCount: chapters.length, latestChapter, updatedAt }),
            aliases: Object.freeze([]), catalogUrl: url.toString(),
        });
        const expiresAtMs = cachedHtml.storedAtMs + cachePolicy.staleAfterMs;
        // Discovery's hydration satisfies both the later detail route and add-to-shelf
        // catalog request after loading every catalog page once.
        const catalog = Object.freeze({ items: Object.freeze(chapters.map((chapter, index) => Object.freeze({
                id: chapter.id, title: chapter.title, order: index, url: chapter.url.toString(), volumeTitle: null,
                wordCount: null, updatedAt: null, isLocked: false, attributes: Object.freeze([]),
            }))) });
        return Object.freeze({ value: Object.freeze({ detail, catalog }), storedAtMs: cachedHtml.storedAtMs });
    }
    async getChapters(request) {
        decodeNovelId(request.id);
        const cached = this.#catalogs.get(request.id);
        if (cached !== undefined && cached.expiresAtMs >= Date.now())
            return cached.value;
        await this.#loadCachedDetail(request, detailProjectionPolicy, detailPolicy);
        const loaded = this.#catalogs.get(request.id);
        if (loaded === undefined)
            throw new Error('Source catalog was not loaded.');
        return loaded.value;
    }
    async getContent(request) {
        const bookId = decodeNovelId(request.id);
        const chapterUrl = this.#decodeChapterId(request.chapterId);
        const firstPage = parseChapterPage(chapterUrl);
        if (firstPage === null || firstPage.bookId !== bookId)
            throw new Error('Chapter ID is invalid.');
        const cheerio = await loadCheerio();
        const visited = new Set();
        const parts = [];
        let pageUrl = chapterUrl;
        let title = null;
        for (let page = 1; page <= 120; page += 1) {
            if (visited.has(pageUrl.toString()))
                throw new Error('Chapter pagination loop detected.');
            visited.add(pageUrl.toString());
            const $ = cheerio.load(await this.#getHtml(pageUrl));
            const content = $('.container .con').first();
            if (content.length === 0)
                throw new Error('Source chapter content was not found.');
            title ??= textOrNull($('.submenu h1').first().text())?.split('>').pop()?.trim() ?? null;
            const nextPage = this.#nextChapterPage($, pageUrl, firstPage);
            content.find('script,style,iframe,.submenu,.prenext').remove();
            const markup = (content.html() ?? '').replace(/<br\s*\/?>(?=.)/giu, '\n').replace(/<\/(?:p|div)>/giu, '\n\n');
            const pageText = cheerio.load(`<body>${markup}</body>`).text().replace(/\r/g, '').replace(/[ \t]+\n/g, '\n').replace(/\n[ \t]+/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
            if (pageText !== '')
                parts.push(pageText);
            if (nextPage === null)
                break;
            pageUrl = nextPage;
            if (page === 120)
                throw new Error('Chapter pagination exceeds the safety limit.');
        }
        const text = parts.join('\n\n').trim();
        return Object.freeze({ chapterId: request.chapterId, contentKind: 'novel', title, updatedAt: null, text, pages: Object.freeze([]) });
    }
    async #getHtml(url, policy) {
        return (await this.#getHtmlResult(url, policy)).body;
    }
    async #getHtmlResult(url, policy) {
        const request = async () => {
            this.context.log.debug('source_http_fetch_started');
            const response = await this.context.http.fetch(url, { headers: { Accept: 'text/html,application/xhtml+xml', 'Accept-Language': 'zh-CN,zh;q=0.9' } });
            if (!response.ok)
                throw new Error(`Source request failed with HTTP ${response.status}.`);
            return response.text();
        };
        return policy === undefined
            ? Object.freeze({ body: await request(), storedAtMs: Date.now() })
            : this.#cache.getOrFetchTextResult(url, policy, request).then((result) => Object.freeze({ body: result.value, storedAtMs: result.storedAtMs }));
    }
    async #parseList(html, pageUrl) {
        const cheerio = await loadCheerio();
        const $ = cheerio.load(html);
        const seen = new Set();
        return Object.freeze($('.item').toArray().flatMap((element) => this.#parseBook($, element, pageUrl, seen)));
    }
    async #loadHomeDiscovery() {
        try {
            const homeUrl = new URL('/', this.#baseUrl);
            const html = await this.#getHtml(homeUrl, discoveryListingPolicy);
            const latest = (await this.#parseList(html, homeUrl)).slice(0, 10);
            const ranked = (await this.#parseHomeLinks(html, homeUrl, '阅读排行', 'ongoing')).slice(0, 8);
            const completedLinks = (await this.#parseHomeLinks(html, homeUrl, '完结小说', 'completed')).slice(0, 6);
            const completed = await this.#withDetails(completedLinks);
            return Object.freeze({ latest: Object.freeze(latest), ranked: Object.freeze(ranked), completed: Object.freeze(completed) });
        }
        catch {
            this.context.log.debug('source_discovery_home_unavailable');
            return Object.freeze({ latest: Object.freeze([]), ranked: Object.freeze([]), completed: Object.freeze([]) });
        }
    }
    async #parseHomeLinks(html, pageUrl, heading, status) {
        const cheerio = await loadCheerio();
        const $ = cheerio.load(html);
        const title = $('h2 a').filter((_, element) => textOrNull($(element).text()) === heading).first();
        if (title.length === 0)
            return Object.freeze([]);
        const section = title.closest('.container');
        const seen = new Set();
        return Object.freeze(section.find('ul.list a[href]').toArray().flatMap((element) => {
            const link = $(element);
            const label = textOrNull(link.text());
            const href = link.attr('href');
            if (label === null || href === undefined)
                return [];
            const url = this.#sourceUrl(href, pageUrl);
            const id = novelIdFromUrl(url);
            if (id === null || seen.has(id))
                return [];
            seen.add(id);
            return [this.#summary({ id, title: label, author: null, category: null, coverUrl: null, description: null, status, wordCount: null, chapterCount: null, latestChapter: null, updatedAt: null })];
        }));
    }
    #discoveryItems(contents, ranked = false) {
        return Object.freeze(contents.map((content, index) => Object.freeze({
            content, rank: ranked ? index + 1 : null, metric: null, recommendation: null,
        })));
    }
    async #parseHotSearches(html) {
        const cheerio = await loadCheerio();
        const $ = cheerio.load(html);
        const heading = $('h2 a').filter((_, element) => textOrNull($(element).text()) === '阅读排行').first();
        if (heading.length === 0)
            return Object.freeze([]);
        const seen = new Set();
        const queries = heading.closest('.container').find('ul.list.top > li p a[href]').toArray().flatMap((element) => {
            const query = textOrNull($(element).text());
            if (query === null || seen.has(query))
                return [];
            seen.add(query);
            return [query];
        });
        return Object.freeze(queries);
    }
    #parseBook($, element, pageUrl, seen) {
        const root = $(element);
        const link = root.find('a[href]').toArray().map((candidate) => $(candidate)).find((candidate) => /^\/\d+\/$/u.test(candidate.attr('href') ?? ''));
        const href = link?.attr('href');
        const title = textOrNull(root.find('.itemtxt h1 a, .itemtxt h3 a').first().text());
        if (href === undefined || title === null)
            return [];
        const url = this.#sourceUrl(href, pageUrl);
        const id = novelIdFromUrl(url);
        if (id === null || seen.has(id))
            return [];
        seen.add(id);
        const spans = root.find('.itemtxt p span').toArray().map((candidate) => textOrNull($(candidate).text())).filter((value) => value !== null);
        const author = textOrNull(root.find('.itemtxt a').filter((_, candidate) => /^作者[：:]/u.test($(candidate).text())).first().text().replace(/^作者[：:]/u, ''));
        const latest = root.find('.itemtxt ul li a').last();
        const latestTitle = textOrNull(latest.text());
        const latestHref = latest.attr('href');
        const latestChapter = latestTitle === null || latestHref === undefined ? null : Object.freeze({ id: this.#chapterId(this.#sourceUrl(latestHref, pageUrl)), title: latestTitle, url: this.#sourceUrl(latestHref, pageUrl).toString(), updatedAt: null });
        return [this.#summary({ id, title, author, category: textOrNull(spans[1]), coverUrl: this.#proxyCoverUrl(root.find('img').first().attr('src'), pageUrl), description: null, status: parseStatus(spans[0]), wordCount: null, chapterCount: null, latestChapter, updatedAt: null })];
    }
    #summary(input) {
        return Object.freeze({ id: `novel:${input.id}`, title: input.title, contentKind: 'novel', author: input.author, url: new URL(`/${input.id}/`, this.#baseUrl).toString(), coverUrl: input.coverUrl, description: input.description, language: 'zh-CN', status: input.status, access: 'free', wordCount: input.wordCount, chapterCount: input.chapterCount, publishedAt: null, updatedAt: input.updatedAt, latestChapter: input.latestChapter, categories: input.category === null ? Object.freeze([]) : Object.freeze([input.category]), tags: Object.freeze([]), attributes: Object.freeze([]) });
    }
    async #withDetails(books) {
        const result = new Array(books.length);
        let next = 0;
        const worker = async () => { while (next < books.length) {
            const index = next++;
            const book = books[index];
            try {
                const detail = await this.#getDiscoveryDetail({ id: book.id });
                result[index] = Object.freeze({ ...book, author: detail.author, url: detail.url, coverUrl: detail.coverUrl, description: detail.description, language: detail.language, status: detail.status, access: detail.access, wordCount: detail.wordCount, chapterCount: detail.chapterCount, publishedAt: detail.publishedAt, updatedAt: detail.updatedAt, latestChapter: detail.latestChapter, categories: detail.categories, tags: detail.tags, attributes: detail.attributes });
            }
            catch {
                result[index] = book;
            }
        } };
        await Promise.all(Array.from({ length: Math.min(4, books.length) }, () => worker()));
        return Object.freeze(result);
    }
    async #getDiscoveryDetail(request) {
        const cached = this.#details.get(request.id);
        if (cached !== undefined && cached.expiresAtMs >= Date.now())
            return cached.value;
        const inFlight = this.#discoveryDetailRequests.get(request.id);
        if (inFlight !== undefined)
            return inFlight;
        const pending = this.#loadCachedDetail(request, discoveryDetailProjectionPolicy, discoveryDetailPolicy).then((projection) => projection.detail);
        this.#discoveryDetailRequests.set(request.id, pending);
        void pending.then(() => this.#discoveryDetailRequests.delete(request.id), () => this.#discoveryDetailRequests.delete(request.id));
        return pending;
    }
    async #loadCachedDetail(request, projectionPolicy, htmlPolicy) {
        const cached = this.#details.get(request.id);
        if (cached !== undefined && cached.expiresAtMs >= Date.now()) {
            const catalog = this.#catalogs.get(request.id)?.value;
            if (catalog !== undefined)
                return Object.freeze({ detail: cached.value, catalog });
        }
        const result = await this.#cache.getOrFetchJsonResult(`detail:${request.id}`, projectionPolicy, () => this.#loadDetailProjection(request, htmlPolicy), decodeDetailProjection);
        const expiresAtMs = result.storedAtMs + projectionPolicy.staleAfterMs;
        this.#details.set(request.id, Object.freeze({ expiresAtMs, value: result.value.detail }));
        this.#catalogs.set(request.id, Object.freeze({ expiresAtMs, value: result.value.catalog }));
        return result.value;
    }
    #parseCatalog($, base) {
        const seen = new Set();
        return Object.freeze($('#list a[href]').toArray().flatMap((element) => { const title = textOrNull($(element).text()); const href = $(element).attr('href'); if (title === null || href === undefined)
            return []; const url = this.#sourceUrl(href, base); const id = this.#chapterId(url); if (seen.has(id))
            return []; seen.add(id); return [Object.freeze({ id, title, url })]; }));
    }
    async #loadCatalog(cheerio, firstHtml, base, bookId, policy) {
        const chapters = [];
        const seen = new Set();
        let pageUrl = base;
        let pageHtml = firstHtml;
        for (let page = 1; page <= 120; page += 1) {
            const $ = cheerio.load(pageHtml);
            for (const chapter of this.#parseCatalog($, pageUrl)) {
                if (seen.has(chapter.id))
                    continue;
                seen.add(chapter.id);
                chapters.push(chapter);
            }
            const nextPage = this.#nextCatalogPage($, pageUrl, bookId);
            if (nextPage === null)
                return Object.freeze(chapters);
            if (page === 120)
                throw new Error('Catalog pagination exceeds the safety limit.');
            pageUrl = nextPage;
            pageHtml = await this.#getHtml(pageUrl, policy);
        }
        throw new Error('Catalog pagination exceeds the safety limit.');
    }
    #nextCatalogPage($, current, bookId) {
        const next = $('.pages a[href], a[rel="next"]').toArray().find((element) => {
            const label = (textOrNull($(element).text()) ?? '').replace(/\s+/gu, '');
            return label === '下一页';
        });
        if (next === undefined)
            return null;
        const href = $(next).attr('href');
        if (href === undefined)
            throw new Error('Catalog continuation is invalid.');
        const candidate = this.#sourceUrl(href, current);
        const currentPage = parseCatalogPage(current, bookId);
        const candidatePage = parseCatalogPage(candidate, bookId);
        if (currentPage === null || candidatePage === null || candidatePage !== currentPage + 1)
            throw new Error('Catalog continuation is invalid.');
        return candidate;
    }
    #nextChapterPage($, current, firstPage) {
        const next = $('.prenext a[href], a[rel="next"]').toArray().find((element) => {
            const label = (textOrNull($(element).text()) ?? '').replace(/\s+/gu, '');
            return /^(?:下一页|下页|next|>|›|»)$/iu.test(label);
        });
        if (next === undefined)
            return null;
        const href = $(next).attr('href');
        if (href === undefined)
            throw new Error('Chapter continuation is invalid.');
        const candidate = this.#sourceUrl(href, current);
        const page = parseChapterPage(candidate);
        const currentPage = parseChapterPage(current);
        if (page === null || currentPage === null || page.bookId !== firstPage.bookId || page.chapterNumber !== firstPage.chapterNumber || page.pageNumber !== currentPage.pageNumber + 1) {
            throw new Error('Chapter continuation is invalid.');
        }
        return candidate;
    }
    #category(target) { const id = target.startsWith('category:') ? target.slice(9) : ''; const result = this.#categories.find((category) => category.id === id); if (result === undefined)
        throw new Error('Category target is invalid.'); return result; }
    #categoryUrl(id, page) { return new URL(page === 1 ? `/${id}/` : `/${id}/${page}.html`, this.#baseUrl); }
    #sourceUrl(value, base) { const url = new URL(value, base); if (url.origin !== this.#baseUrl.origin || url.protocol !== 'https:')
        throw new Error('Source URL is invalid.'); return url; }
    #proxyCoverUrl(value, base) {
        const url = publicHttpUrl(value, base);
        if (url === null || new URL(url).origin !== this.#baseUrl.origin)
            return null;
        return this.context.resource.proxy({ kind: 'image', url, headers: { Accept: 'image/*' } });
    }
    #chapterId(url) { if (parseChapterPage(url) === null)
        throw new Error('Chapter URL is invalid.'); return `chapter:${Buffer.from(url.pathname).toString('base64url')}`; }
    #decodeChapterId(id) { if (!id.startsWith('chapter:'))
        throw new Error('Chapter ID is invalid.'); const path = Buffer.from(id.slice(8), 'base64url').toString('utf8'); const url = this.#sourceUrl(path, this.#baseUrl); if (parseChapterPage(url) === null)
        throw new Error('Chapter ID is invalid.'); return url; }
}
function categoryIcon(id, title) {
    if (id === 'dushi')
        return 'urban';
    if (id === 'xuanhuan' || id === 'qihuan' || id === 'xianxia')
        return 'fantasy';
    if (id === 'qing')
        return 'lightNovel';
    if (id === 'lishi')
        return 'history';
    if (id === 'kehuan' || id === 'zhutianwuxian')
        return 'scienceFiction';
    if (id === 'youxi')
        return 'game';
    if (id === 'xuanyi')
        return 'mystery';
    if (id === 'tiyu')
        return 'sports';
    if (id === 'junshi')
        return 'military';
    if (id === 'wuxia')
        return 'wuxia';
    if (id === 'xiangcun')
        return 'rural';
    if (id === 'yanqing')
        return 'romance';
    if (title.includes('官场') || title.includes('现实'))
        return 'globe';
    return 'category';
}
function documentResult(section) { return Object.freeze({ kind: 'document', document: Object.freeze({ components: Object.freeze([section]) }) }); }
function required(value) { const result = textOrNull(value); if (result === null)
    throw new Error('Required source field is empty.'); return result; }
function textOrNull(value) { return nonBlank(value); }
function novelIdFromUrl(url) { return /^\/(\d+)\/$/u.exec(url.pathname)?.[1] ?? null; }
function decodeNovelId(id) { const value = /^novel:(\d+)$/u.exec(id)?.[1]; if (value === undefined)
    throw new Error('Novel ID is invalid.'); return value; }
function parseChapterPage(url) { const match = /^\/(\d+)\/(\d+)(?:-(\d+))?\.html$/u.exec(url.pathname); if (match === null)
    return null; const pageNumber = Number(match[3] ?? '1'); return Number.isSafeInteger(pageNumber) && pageNumber >= 1 ? Object.freeze({ bookId: match[1], chapterNumber: match[2], pageNumber }) : null; }
function parseCatalogPage(url, bookId) { if (url.pathname === `/${bookId}/`)
    return 1; const match = new RegExp(`^/${bookId}/p-(\\d+)\\.html$`, 'u').exec(url.pathname); if (match === null)
    return null; const page = Number(match[1]); return Number.isSafeInteger(page) && page >= 2 ? page : null; }
function decodePage(cursor, scope) { if (cursor === null)
    return 1; const value = Number(new RegExp(`^${scope}:(\\d+)$`, 'u').exec(cursor)?.[1] ?? Number.NaN); if (!Number.isSafeInteger(value) || value < 1)
    throw new Error('Cursor is invalid.'); return value; }
function boundedPageSize(value) { if (!Number.isSafeInteger(value) || value < 1)
    throw new Error('Page size is invalid.'); return Math.min(value, 100); }
function parseSearchTotal(value) { const count = Number(/共(\d+)本小说/u.exec(value.replace(/\s+/g, ''))?.[1] ?? Number.NaN); return Number.isSafeInteger(count) && count >= 0 ? count : null; }
function parseCount(value, suffix) { const match = /([\d.]+)(万|亿)?/u.exec(value); if (match === null)
    return null; const number = Number(match[1]); const result = Math.round(number * (match[2] === '万' ? 10000 : match[2] === '亿' ? 100000000 : 1)); return Number.isSafeInteger(result) && result >= 0 && value.includes(suffix) ? result : null; }
function parseStatus(value) { const text = value ?? ''; if (/连载|更新中/u.test(text))
    return 'ongoing'; if (/完结/u.test(text))
    return 'completed'; if (/暂停|断更|停更/u.test(text))
    return 'hiatus'; return 'unknown'; }
function parseDate(value) { const match = /(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?/u.exec(value); if (match === null)
    return null; const iso = `${match[1]}-${match[2]}-${match[3]}T${match[4]}:${match[5]}:${match[6] ?? '00'}+08:00`; return Number.isNaN(Date.parse(iso)) ? null : new Date(iso).toISOString(); }
function publicHttpUrl(value, base) { if (value === undefined)
    return null; try {
    const url = new URL(value, base);
    return (url.protocol === 'http:' || url.protocol === 'https:') && url.username === '' && url.password === '' ? url.toString() : null;
}
catch {
    return null;
} }
function decodeDetailProjection(value) {
    if (!isRecord(value) || !isRecord(value.detail) || !isRecord(value.catalog))
        return undefined;
    const detail = value.detail;
    const catalog = value.catalog;
    if (!Array.isArray(catalog.items))
        return undefined;
    if (typeof detail.id !== 'string' || typeof detail.title !== 'string' || detail.contentKind !== 'novel' || !Array.isArray(detail.aliases) || !(typeof detail.catalogUrl === 'string' || detail.catalogUrl === null))
        return undefined;
    if (!catalog.items.every((item) => isRecord(item) && typeof item.id === 'string' && typeof item.title === 'string' && Number.isSafeInteger(item.order)))
        return undefined;
    return Object.freeze({ detail: detail, catalog: catalog });
}
function isRecord(value) { return typeof value === 'object' && value !== null && !Array.isArray(value); }
