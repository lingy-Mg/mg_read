/** Public Rehanman page parser. */
import { Buffer } from 'node:buffer';
const siteOrigin = 'https://rehanman.com';
const imageOrigin = 'https://img.rehanman.com';
const graphQlUrl = 'https://api.rehanman.com/manga-graphql';
const entriesQuery = 'query entries($inputs: InputEntries) { entries(inputs: $inputs) { docs { title title_normalized description thumbnail authors { name } genres { name } created_date modified_date status entries_setting { premium isHide } } totalPages totalDocs page } }';
export class RehanmanSource {
    context;
    constructor(context) {
        this.context = context;
    }
    async latest(page) { return this.#entries({ type: 'new', page, limit: 30 }); }
    async search(query, page) { return this.#entries({ type: 'search', key: query, page, limit: 30 }); }
    async detail(id) { const entry = await this.#entry(id); return Object.freeze({ ...this.#summary(entry), aliases: Object.freeze([]), catalogUrl: bookUrl(entry).toString() }); }
    async chapters(id) { const entry = await this.#entry(id); this.#assertFree(entry); const chapters = entry.entries_data?.chapters ?? []; return Object.freeze({ items: Object.freeze(chapters.map((chapter) => Object.freeze({ id: chapterId(entry, chapter), title: chapter.name, order: chapter.index, url: chapterUrl(entry, chapter).toString(), volumeTitle: entry.entries_data?.volume_name ?? null, wordCount: null, updatedAt: entry.modified_date, isLocked: false, attributes: Object.freeze([]) }))) }); }
    async content(id, idForChapter) { const entry = await this.#entry(id); this.#assertFree(entry); const chapter = (entry.entries_data?.chapters ?? []).find((value) => chapterId(entry, value) === idForChapter); if (chapter === undefined)
        throw new Error('Chapter ID is invalid.'); const images = chapter.images.flatMap((path) => imageUrl(path) === null ? [] : [imageUrl(path)]); if (images.length === 0)
        throw new Error('Chapter images are missing.'); const referer = chapterUrl(entry, chapter); return Object.freeze({ chapterId: idForChapter, contentKind: 'manga', title: chapter.name, updatedAt: entry.modified_date, text: null, pages: Object.freeze(images.map((url, index) => Object.freeze({ id: `page:${index + 1}`, index, url: this.#proxyImage(url, referer), mimeType: mime(url), width: null, height: null }))) }); }
    async #entry(id) { const url = bookUrlFromId(id); const page = await this.#page(url); const entry = parseEntry(object(object(page.props)?.pageProps)?.entrySSR); if (entry === null || entry.title_normalized !== tokenFromId(id))
        throw new Error('Content detail is invalid.'); return entry; }
    async #entries(inputs) { const response = await this.context.http.fetch(graphQlUrl, { method: 'POST', headers: { accept: 'application/json', 'content-type': 'application/json' }, body: JSON.stringify({ query: entriesQuery, variables: { inputs: { ...inputs, adult: true, is_hide: false } } }) }); if (!response.ok)
        throw new Error('Source listing is unavailable.'); const payload = object(await response.json()); const entries = object(object(payload?.data)?.entries); const items = array(entries?.docs).flatMap((value) => { const entry = parseEntry(value); return entry === null ? [] : [this.#summary(entry)]; }); const current = number(entries?.page); const totalPages = number(entries?.totalPages); const totalCount = number(entries?.totalDocs); if (current === null || totalPages === null || totalCount === null)
        throw new Error('Source listing is invalid.'); return Object.freeze({ items: Object.freeze(items), hasNext: current < totalPages, totalCount }); }
    #summary(entry) { const cover = entry.thumbnail === null ? null : imageUrl(entry.thumbnail); return summary(entry, cover === null ? null : this.#proxyImage(cover, bookUrl(entry))); }
    async #page(url) { const response = await this.context.http.fetch(url, { headers: { accept: 'text/html,application/xhtml+xml', referer: `${siteOrigin}/` } }); if (!response.ok)
        throw new Error('Source page is unavailable.'); return parseNextData(await response.text()); }
    #proxyImage(url, referer) { if (imageUrl(url.toString()) === null || referer.origin !== siteOrigin)
        throw new Error('Image request is invalid.'); return this.context.resource.proxy({ kind: 'rehanman-image', url: url.toString(), headers: { Accept: 'image/*', Referer: `${siteOrigin}/` } }); }
    #assertFree(entry) { if (entry.entries_setting.some((setting) => setting.premium || setting.isHide))
        throw new Error('Content is not publicly available.'); }
}
function parseNextData(html) { const match = /<script id="__NEXT_DATA__" type="application\/json">(?<json>[\s\S]*?)<\/script>/u.exec(html); if (match?.groups?.json === undefined)
    throw new Error('Source response does not contain page data.'); try {
    return JSON.parse(match.groups.json);
}
catch {
    throw new Error('Source page data is invalid.');
} }
function parseEntry(value) { const raw = object(value); const title = text(raw?.title); const normalized = text(raw?.title_normalized); if (title === null || normalized === null || !/^\d+$/u.test(normalized))
    return null; const entryData = object(raw?.entries_data); const chapters = array(entryData?.chapters).flatMap((chapter) => { const current = object(chapter); const name = text(current?.name); const index = number(current?.index); const images = array(current?.images).flatMap((image) => typeof image === 'string' ? [image] : []); return name === null || index === null ? [] : [Object.freeze({ name, index, images: Object.freeze(images) })]; }); return Object.freeze({ title, title_normalized: normalized, description: text(raw?.description), thumbnail: text(raw?.thumbnail), authors: names(raw?.authors), genres: names(raw?.genres), created_date: text(raw?.created_date), modified_date: text(raw?.modified_date), status: text(raw?.status), entries_data: entryData === undefined ? null : Object.freeze({ volume_name: text(entryData.volume_name), chapters: Object.freeze(chapters) }), entries_setting: array(raw?.entries_setting).flatMap((setting) => { const current = object(setting); return typeof current?.premium === 'boolean' && typeof current.isHide === 'boolean' ? [Object.freeze({ premium: current.premium, isHide: current.isHide })] : []; }) }); }
function summary(entry, coverUrl) { const chapters = entry.entries_data?.chapters ?? []; const last = chapters.at(-1) ?? null; return Object.freeze({ id: contentId(entry.title_normalized), title: entry.title, contentKind: 'manga', author: entry.authors[0] ?? null, url: bookUrl(entry).toString(), coverUrl, description: entry.description, language: null, status: 'unknown', access: 'free', wordCount: null, chapterCount: chapters.length, publishedAt: entry.created_date, updatedAt: entry.modified_date, latestChapter: { id: last === null ? `chapter:${entry.title_normalized}:none` : chapterId(entry, last), title: last?.name ?? '暂无章节', url: last === null ? bookUrl(entry).toString() : chapterUrl(entry, last).toString(), updatedAt: entry.modified_date }, categories: entry.genres, tags: entry.genres, attributes: Object.freeze([]) }); }
function contentId(token) { return `webtoon:${token}`; }
function tokenFromId(id) { const match = /^webtoon:(\d+)$/u.exec(id); if (match?.[1] === undefined)
    throw new Error('Content ID is invalid.'); return match[1]; }
function bookUrlFromId(id) { return new URL(`/webtoon/${tokenFromId(id)}`, siteOrigin); }
function bookUrl(entry) { return bookUrlFromId(contentId(entry.title_normalized)); }
function chapterId(entry, chapter) { return `chapter:${entry.title_normalized}:${chapter.index}`; }
function chapterUrl(entry, chapter) { const volume = entry.entries_data?.volume_name ?? '00'; return new URL(`/webtoon/${entry.title_normalized}/${volume}/ch-${chapter.index + 1}`, siteOrigin); }
function imageUrl(value) { try {
    const url = /^https?:\/\//iu.test(value) ? new URL(value) : new URL(`/uploads/data/china18sky/${value.replace(/^\/+/, '')}`, imageOrigin);
    return url.origin === imageOrigin && /^\/uploads\/data\/china18sky\/[\w/-]+\.(?:jpe?g|png|webp|gif)$/iu.test(url.pathname) ? url : null;
}
catch {
    return null;
} }
function object(value) { return value !== null && typeof value === 'object' && !Array.isArray(value) ? value : undefined; }
function array(value) { return Array.isArray(value) ? value : []; }
function text(value) { return typeof value === 'string' && value.trim() !== '' ? value.trim() : null; }
function number(value) { return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0 ? value : null; }
function names(value) { return Object.freeze(array(value).flatMap((item) => text(object(item)?.name) ?? [])); }
function mime(url) { const extension = /\.([^.]+)$/u.exec(url.pathname)?.[1]?.toLowerCase(); return extension === 'jpg' || extension === 'jpeg' ? 'image/jpeg' : extension === 'png' ? 'image/png' : extension === 'webp' ? 'image/webp' : extension === 'gif' ? 'image/gif' : null; }
