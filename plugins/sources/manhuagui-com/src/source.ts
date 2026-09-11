/**
 * Public Manhuagui page parser.
 * Owns stable manga/chapter IDs, bounded P.A.C.K.E.R decoding, and Runtime-proxied images with chapter Referer.
 */
import LZString from 'lz-string';
import type {
  Chapter, ChapterContent, Continuation, Detail, DiscoveryItem, MgReadPluginContext,
  Status, Summary,
} from './mgread-api.js';

const desktopOrigin = 'https://www.manhuagui.com';
const mobileOrigin = 'https://m.manhuagui.com';
const defaultImageOrigin = 'https://i.hamreus.com';
const packedLimit = 1024 * 1024;
const unpackedLimit = 2 * 1024 * 1024;

const categories = Object.freeze([
  { id: 'update', title: '最新更新', path: '/update/' },
  { id: 'rank', title: '排行榜', path: '/rank/' },
  { id: 'all', title: '漫画大全', path: '/list/' },
  { id: 'ongoing', title: '连载漫画', path: '/list/lianzai/' },
  { id: 'completed', title: '完结漫画', path: '/list/wanjie/' },
  { id: 'japan', title: '日本漫画', path: '/list/japan/' },
  { id: 'hongkong', title: '港台漫画', path: '/list/hongkong/' },
  { id: 'europe', title: '欧美漫画', path: '/list/europe/' },
  { id: 'korea', title: '韩国漫画', path: '/list/korea/' },
  { id: 'china', title: '内地漫画', path: '/list/china/' },
]);

interface BookKey { readonly book: string }
interface ChapterKey extends BookKey { readonly chapter: string }
interface PackedData {
  readonly files: readonly string[]; readonly host: string; readonly path: string;
  readonly e: string | null; readonly m: string | null; readonly cid: string | null; readonly md5: string | null;
}

export class ManhuaguiSource {
  constructor(private readonly context: MgReadPluginContext) {}

  async home(pageSize: number): Promise<{ readonly items: readonly Summary[] }> {
    const url = new URL('/update/', mobileOrigin);
    return { items: this.#parseCards(await this.#html(url, mobileOrigin), url).slice(0, boundedPageSize(pageSize)) };
  }

  async category(target: string, cursor: string | null, pageSize: number): Promise<{
    readonly title: string; readonly collectionId: string; readonly items: readonly DiscoveryItem[]; readonly continuation: Continuation | null;
  }> {
    const category = decodeCategory(target); const page = decodeCursor(cursor);
    const url = categoryUrl(category.path, page);
    const html = await this.#html(url, mobileOrigin);
    const items = this.#parseCards(html, url).slice(0, boundedPageSize(pageSize)).map(toDiscoveryItem);
    const continuation = findNextPage(html, category.path, page)
      ? { target, cursor: String(page + 1) }
      : null;
    return { title: category.title, collectionId: `manhuagui-${category.id}`, items, continuation };
  }

  categoryMetadata() {
    return categories.map((category) => ({
      id: `category-${category.id}`, title: category.title, target: `category:${category.id}`,
      count: null, url: new URL(category.path, mobileOrigin).toString(), icon: categoryIcon(category.id),
    }));
  }

  async search(query: string, pageSize: number): Promise<readonly Summary[]> {
    const normalized = query.trim(); if (normalized === '') return [];
    const url = new URL(`/s/${encodeURIComponent(normalized)}.html`, mobileOrigin);
    return this.#parseCards(await this.#html(url, mobileOrigin), url).slice(0, boundedPageSize(pageSize));
  }

  async detail(id: string): Promise<Detail> {
    const key = decodeBookId(id); const url = bookUrl(key);
    const html = await this.#html(url, desktopOrigin);
    const title = textFromMatch(html, /<h1[^>]*>([\s\S]*?)<\/h1>/iu);
    if (title === null) throw new Error('Source detail title is missing.');
    const author = textFromMatch(html, /漫画作者：<\/strong>([\s\S]*?)<\/span>/iu);
    const categoryText = textFromMatch(html, /漫画剧情：<\/strong>([\s\S]*?)<\/span>/iu);
    const statusText = textFromMatch(html, /漫画状态：<\/strong>\s*<span[^>]*>([\s\S]*?)<\/span>/iu);
    const coverBlock = firstCapture(html, /<p[^>]*class=["'][^"']*hcover[^"']*["'][^>]*>([\s\S]*?)<\/p>/iu) ?? '';
    const coverTag = firstCapture(coverBlock, /(<img\b[^>]*>)/iu);
    const cover = normalizeImageUrl(coverTag === null ? undefined : attribute(coverTag, 'src'), url);
    const description = textFromMatch(html, /<div[^>]*id=["']intro-all["'][^>]*>([\s\S]*?)<\/div>/iu)
      ?? textFromMatch(html, /<div[^>]*id=["']intro-cut["'][^>]*>([\s\S]*?)<\/div>/iu);
    const latestBlock = firstCapture(html, /最近于[\s\S]*?更新至\s*\[([\s\S]*?)\]/iu) ?? '';
    const latestLink = firstLink(latestBlock, /\/comic\/\d+\/\d+\.html$/u);
    const latestUrl = latestLink === undefined ? null : normalizePageUrl(latestLink.href, url);
    const chapters = parseChapters(html, key);
    const aliases = textFromMatch(html, /漫画别名：<\/strong>([\s\S]*?)<\/span>/iu);
    return {
      ...makeSummary({
        key, title, author, category: categoryText, coverUrl: this.#proxyImage(cover, url), description,
        status: parseStatus(statusText), chapterCount: chapters.length,
        latest: latestUrl === null || latestLink === undefined || latestLink.title === null ? null : {
          id: chapterIdFromUrl(latestUrl), title: latestLink.title, url: latestUrl.toString(), updatedAt: null,
        },
      }),
      aliases: aliases === null || aliases === '暂无' ? [] : [aliases],
      catalogUrl: url.toString(),
    };
  }

  async chapters(id: string): Promise<{ readonly items: readonly Chapter[] }> {
    const key = decodeBookId(id); const html = await this.#html(bookUrl(key), desktopOrigin);
    return { items: parseChapters(html, key) };
  }

  async content(id: string, idForChapter: string): Promise<ChapterContent> {
    const book = decodeBookId(id); const chapter = decodeChapterId(idForChapter);
    if (book.book !== chapter.book) throw new Error('Chapter does not belong to the requested manga.');
    const url = chapterUrl(chapter); const html = await this.#html(url, desktopOrigin);
    const data = parsePackedImageData(html); const images = buildImageUrls(data);
    if (images.length === 0) throw new Error('Source chapter images are missing.');
    const title = titleWithoutSuffix(textFromMatch(html, /<title[^>]*>([\s\S]*?)<\/title>/iu));
    return {
      chapterId: idForChapter, contentKind: 'manga', title, updatedAt: null, text: null,
      pages: images.map((image, index) => ({
        id: `page:${chapter.chapter}:${index + 1}`, index,
        url: this.#proxyImage(image, url)!, mimeType: mimeType(image), width: null, height: null,
      })),
    };
  }

  #parseCards(html: string, pageUrl: URL): Summary[] {
    const list = firstCapture(html, /<div\s+class=["'][^"']*cont-list[^"']*["'][^>]*>[\s\S]*?<ul[^>]*id=["']detail["'][^>]*>([\s\S]*?)<\/ul>/iu) ?? html;
    const output: Summary[] = []; const seen = new Set<string>();
    for (const item of captures(list, /<li\b[^>]*>([\s\S]*?)<\/li>/giu)) {
      const link = firstLink(item, /\/comic\/\d+\/?$/u); if (link === undefined) continue;
      const contentUrl = normalizePageUrl(link.href, pageUrl); if (contentUrl === null) continue;
      const key = bookKeyFromUrl(contentUrl); if (seen.has(key.book)) continue; seen.add(key.book);
      const title = textFromMatch(item, /<h3[^>]*>([\s\S]*?)<\/h3>/iu) ?? link.title;
      if (title === null) continue;
      const imageTag = firstCapture(item, /(<img\b[^>]*>)/iu);
      const cover = normalizeImageUrl(imageTag === null ? undefined : attribute(imageTag, 'data-src') ?? attribute(imageTag, 'src'), pageUrl);
      const status = textFromMatch(item, /<i[^>]*>([\s\S]*?)<\/i>/iu);
      const author = definition(item, '作\s*者'); const category = definition(item, '类\s*别');
      const latestTitle = definition(item, '更新至'); const latest = latestTitle === null ? null : { id: null, title: latestTitle, url: null, updatedAt: null };
      output.push(makeSummary({
        key, title, author, category, coverUrl: this.#proxyImage(cover, pageUrl), description: null,
        status: parseStatus(status), chapterCount: null, latest,
      }));
    }
    return output;
  }

  async #html(url: URL, refererOrigin: string): Promise<string> {
    if (!allowedPage(url)) throw new Error('Source page URL is invalid.');
    const response = await this.context.http.fetch(url, { headers: { accept: 'text/html,application/xhtml+xml', referer: `${refererOrigin}/` } });
    if (!response.ok) {
      if (response.status === 403 || response.status === 429) this.context.errors.raise({ code: 'source_access_blocked', message: '访问异常，请稍后再试。', annotation: `HTTP ${response.status}` });
      throw new Error('Source page request failed.');
    }
    const html = await response.text();
    if (/cf-challenge|cf-turnstile|正在检查您的浏览器|人机验证/iu.test(html)) throw new Error('Source interaction is required.');
    return html;
  }

  #proxyImage(url: URL | null, referer: URL): string | null {
    return url === null || !allowedImage(url) || !allowedReferer(referer) ? null : this.context.resource.proxy({ kind: 'manhuagui-image', url: url.toString(), headers: { Accept: 'image/*', Referer: referer.toString() } });
  }
}

function parsePackedImageData(html: string): PackedData {
  const code = unpackPackedImageCode(html);
  const json = extractJsonObject(code, 'SMH.imgData(');
  let raw: unknown; try { raw = JSON.parse(json); } catch { throw new Error('Source image data JSON is invalid.'); }
  if (!isRecord(raw) || !Array.isArray(raw.files)) throw new Error('Source image data shape is invalid.');
  const files = raw.files.flatMap((value) => typeof value === 'string' && value !== '' ? [value] : []);
  if (files.length === 0 || files.length > 5000) throw new Error('Source image count is invalid.');
  const sl = isRecord(raw.sl) ? raw.sl : undefined;
  return {
    files, host: stringValue(raw.host) ?? stringValue(raw.domain) ?? stringValue(raw.server) ?? defaultImageOrigin,
    path: stringValue(raw.path) ?? '', e: stringValue(sl?.e), m: stringValue(sl?.m),
    cid: stringValue(raw.cid), md5: stringValue(raw.md5),
  };
}

/** Exposed only from the parser module so deterministic fixtures can pin the non-eval unpacking algorithm. */
export function unpackPackedImageCode(html: string): string {
  if (html.length > unpackedLimit) throw new Error('Source chapter page is too large.');
  const marker = html.includes("}('") ? html.indexOf("}('") + 2 : html.indexOf('}("') + 2;
  if (marker < 2) throw new Error('Source packed image data is missing.');
  const args = readPackedArgs(html, marker);
  if (args.packed.length > packedLimit || args.count > 4096 || args.radix < 2 || args.radix > 62) throw new Error('Source packed image data exceeds limits.');
  const dictionaryText = args.dictionary.includes('|') ? args.dictionary : LZString.decompressFromBase64(args.dictionary);
  if (dictionaryText === null || dictionaryText.length > unpackedLimit) throw new Error('Source packed dictionary is invalid.');
  const code = unpackCode(args.packed, args.radix, args.count, dictionaryText.split('|'));
  if (code.length > unpackedLimit) throw new Error('Source unpacked image data exceeds limits.');
  return code;
}

function buildImageUrls(data: PackedData): URL[] {
  const host = normalizeHost(data.host);
  return data.files.map((file) => {
    const url = /^https?:\/\//iu.test(file) ? new URL(file) : new URL(joinPath(data.path, file), host);
    if (!allowedImage(url)) throw new Error('Source image URL is outside the allowed hosts.');
    if (data.e !== null) url.searchParams.set('e', data.e);
    if (data.m !== null) url.searchParams.set('m', data.m);
    if (data.e === null && data.m === null && data.cid !== null && data.md5 !== null) {
      url.searchParams.set('cid', data.cid); url.searchParams.set('md5', data.md5);
    }
    return url;
  });
}

function parseChapters(html: string, key: BookKey): Chapter[] {
  const start = html.indexOf('章节全集'); const scoped = start < 0 ? html : html.slice(start);
  const endCandidates = ['<div class="comment', '<div class="fr w250"'].map((needle) => scoped.indexOf(needle)).filter((value) => value > 0);
  const section = endCandidates.length === 0 ? scoped : scoped.slice(0, Math.min(...endCandidates));
  const seen = new Set<string>(); const output: Chapter[] = [];
  for (const link of links(section)) {
    const url = normalizePageUrl(link.href, new URL('/', desktopOrigin));
    if (url === null || !new RegExp(`^/comic/${key.book}/\\d+\\.html$`, 'u').test(url.pathname)) continue;
    const chapter = chapterKeyFromUrl(url); if (seen.has(chapter.chapter)) continue; seen.add(chapter.chapter);
    output.push({ id: encodeChapterId(chapter), title: attribute(link.tag, 'title') ?? link.title ?? '章节', order: Number(chapter.chapter), url: url.toString(), volumeTitle: null, wordCount: null, updatedAt: null, isLocked: false, attributes: [] });
  }
  output.sort((left, right) => left.order - right.order);
  return output.map((chapter, order) => ({ ...chapter, order }));
}

function makeSummary(input: {
  readonly key: BookKey; readonly title: string; readonly author: string | null; readonly category: string | null;
  readonly coverUrl: string | null; readonly description: string | null; readonly status: Status;
  readonly chapterCount: number | null; readonly latest: Summary['latestChapter'];
}): Summary {
  return { id: encodeBookId(input.key), title: input.title, contentKind: 'manga', author: input.author,
    url: bookUrl(input.key).toString(), coverUrl: input.coverUrl, description: input.description, language: 'zh-CN',
    status: input.status, access: 'free', wordCount: null, chapterCount: input.chapterCount,
    publishedAt: null, updatedAt: null, latestChapter: input.latest,
    categories: input.category === null ? [] : input.category.split(/[,，]/u).map((value) => value.trim()).filter(Boolean),
    tags: [], attributes: [] };
}

function toDiscoveryItem(content: Summary): DiscoveryItem { return { content, rank: null, metric: null, recommendation: null }; }
function boundedPageSize(value: number) { if (!Number.isSafeInteger(value) || value <= 0) throw new Error('Page size is invalid.'); return Math.min(value, 50); }
function decodeCategory(target: string) { const id = target.startsWith('category:') ? target.slice(9) : ''; const value = categories.find((item) => item.id === id); if (value === undefined) throw new Error('Category target is invalid.'); return value; }
function decodeCursor(value: string | null) { if (value === null) return 1; if (!/^\d+$/u.test(value)) throw new Error('Category cursor is invalid.'); const page = Number(value); if (!Number.isSafeInteger(page) || page < 1 || page > 10_000) throw new Error('Category cursor is invalid.'); return page; }
function categoryUrl(path: string, page: number) { if (page === 1) return new URL(path, mobileOrigin); return new URL(`${path.endsWith('/') ? path : `${path}/`}index_p${page}.html`, mobileOrigin); }
function findNextPage(html: string, path: string, page: number) { return links(html).some((link) => new URL(link.href, mobileOrigin).pathname === categoryUrl(path, page + 1).pathname); }
function categoryIcon(id: string) { return id === 'rank' ? 'ranking' : id === 'completed' ? 'completed' : id === 'ongoing' ? 'ongoing' : id === 'update' ? 'newRelease' : 'manga'; }
function definition(input: string, label: string) { return textFromMatch(input, new RegExp(`<dt>\\s*${label}\\s*[：:]?\\s*<\\/dt>\\s*<dd>([\\s\\S]*?)<\\/dd>`, 'iu')); }
function parseStatus(value: string | null): Status { if (value === null) return 'unknown'; if (/完结|完本/iu.test(value)) return 'completed'; if (/连载/iu.test(value)) return 'ongoing'; if (/停更|暂停/iu.test(value)) return 'hiatus'; return 'unknown'; }
function titleWithoutSuffix(value: string | null) { return value === null ? null : text(value.split('_')[0] ?? value); }

function encodeBookId(key: BookKey) { return `manga:${key.book}`; }
function decodeBookId(id: string): BookKey { const match = /^manga:(\d+)$/u.exec(id); if (match?.[1] === undefined) throw new Error('Content ID is invalid.'); return { book: match[1] }; }
function bookKeyFromUrl(url: URL): BookKey { const match = /^\/comic\/(\d+)\/?$/u.exec(url.pathname); if (match?.[1] === undefined) throw new Error('Source manga URL is invalid.'); return { book: match[1] }; }
function encodeChapterId(key: ChapterKey) { return `chapter:${key.book}:${key.chapter}`; }
function decodeChapterId(id: string): ChapterKey { const match = /^chapter:(\d+):(\d+)$/u.exec(id); if (match?.[1] === undefined || match[2] === undefined) throw new Error('Chapter ID is invalid.'); return { book: match[1], chapter: match[2] }; }
function chapterIdFromUrl(url: URL) { return encodeChapterId(chapterKeyFromUrl(url)); }
function chapterKeyFromUrl(url: URL): ChapterKey { const match = /^\/comic\/(\d+)\/(\d+)\.html$/u.exec(url.pathname); if (match?.[1] === undefined || match[2] === undefined) throw new Error('Source chapter URL is invalid.'); return { book: match[1], chapter: match[2] }; }
function bookUrl(key: BookKey) { return new URL(`/comic/${key.book}/`, desktopOrigin); }
function chapterUrl(key: ChapterKey) { return new URL(`/comic/${key.book}/${key.chapter}.html`, desktopOrigin); }

function allowedPage(url: URL) { return url.protocol === 'https:' && (url.origin === desktopOrigin || url.origin === mobileOrigin); }
function allowedReferer(url: URL) { return allowedPage(url) && (/^\/comic\/\d+(?:\/\d+\.html)?\/?$/u.test(url.pathname) || url.origin === mobileOrigin); }
function allowedImage(url: URL) { return url.protocol === 'https:' && (url.hostname === 'cf.mhgui.com' || url.hostname === 'i.hamreus.com') && url.pathname.length > 1; }
function normalizePageUrl(value: string | undefined, base: URL): URL | null { if (value === undefined || value === '') return null; const url = new URL(value, base); return allowedPage(url) ? new URL(url.pathname + url.search, desktopOrigin) : null; }
function normalizeImageUrl(value: string | undefined, base: URL): URL | null { if (value === undefined || value === '') return null; const url = value.startsWith('//') ? new URL(`https:${value}`) : new URL(value, base); return allowedImage(url) ? url : null; }
function normalizeHost(value: string) { const normalized = value.startsWith('//') ? `https:${value}` : /^https?:\/\//iu.test(value) ? value : `https://${value}`; const url = new URL(normalized); if (!allowedImage(new URL('/placeholder.jpg', url))) throw new Error('Source image host is invalid.'); return url; }
function joinPath(path: string, file: string) { return `/${[path, file].map((value) => value.replace(/^\/+|\/+$/gu, '')).filter(Boolean).join('/')}`; }
function mimeType(url: URL) { const extension = /\.([^.]+)$/u.exec(url.pathname)?.[1]?.toLowerCase(); return extension === 'jpg' || extension === 'jpeg' ? 'image/jpeg' : extension === 'png' ? 'image/png' : extension === 'webp' ? 'image/webp' : extension === 'gif' ? 'image/gif' : null; }

function readPackedArgs(input: string, offset: number) {
  const packed = readQuoted(input, offset); if (packed === null) throw new Error('Packed source argument is invalid.');
  const radix = readNumber(input, skipComma(input, packed.end)); if (radix === null) throw new Error('Packed radix is invalid.');
  const count = readNumber(input, skipComma(input, radix.end)); if (count === null) throw new Error('Packed count is invalid.');
  const dictionary = readQuoted(input, skipComma(input, count.end)); if (dictionary === null) throw new Error('Packed dictionary is invalid.');
  return { packed: packed.value, radix: radix.value, count: count.value, dictionary: dictionary.value };
}
function skipComma(input: string, offset: number) { let index = offset; while (/[\s,]/u.test(input[index] ?? '')) index += 1; return index; }
function readNumber(input: string, offset: number) { const match = /^\d+/u.exec(input.slice(offset)); return match === null ? null : { value: Number(match[0]), end: offset + match[0].length }; }
function readQuoted(input: string, offset: number): { readonly value: string; readonly end: number } | null {
  const quote = input[offset]; if (quote !== "'" && quote !== '"') return null; let value = ''; let index = offset + 1;
  while (index < input.length) { const character = input[index]!; if (character === quote) return { value, end: index + 1 };
    if (character !== '\\') { value += character; index += 1; continue; }
    const escaped = input[index + 1]; if (escaped === undefined) return null;
    if (escaped === 'x') { value += String.fromCharCode(Number.parseInt(input.slice(index + 2, index + 4), 16)); index += 4; }
    else if (escaped === 'u') { value += String.fromCharCode(Number.parseInt(input.slice(index + 2, index + 6), 16)); index += 6; }
    else { value += escaped === 'n' ? '\n' : escaped === 'r' ? '\r' : escaped === 't' ? '\t' : escaped; index += 2; }
  } return null;
}
function unpackCode(packed: string, radix: number, count: number, words: readonly string[]) { const dictionary = new Map<string, string>(); for (let index = count - 1; index >= 0; index -= 1) { const key = baseEncode(index, radix); const value = words[index]; dictionary.set(key, value === undefined || value === '' ? key : value); } return packed.replace(/\b\w+\b/gu, (word) => dictionary.get(word) ?? word); }
function baseEncode(value: number, radix: number) { const characters = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'; if (value === 0) return '0'; let output = ''; let remaining = value; while (remaining > 0) { output = characters[remaining % radix]! + output; remaining = Math.floor(remaining / radix); } return output; }
function extractJsonObject(code: string, marker: string) { const markerIndex = code.indexOf(marker); const start = code.indexOf('{', markerIndex + marker.length); if (markerIndex < 0 || start < 0) throw new Error('Source image object is missing.'); let depth = 0; let quote = ''; let escaped = false; for (let index = start; index < code.length; index += 1) { const character = code[index]!; if (quote !== '') { if (escaped) escaped = false; else if (character === '\\') escaped = true; else if (character === quote) quote = ''; continue; } if (character === '"' || character === "'") { quote = character; continue; } if (character === '{') depth += 1; if (character === '}') { depth -= 1; if (depth === 0) return code.slice(start, index + 1); } } throw new Error('Source image object is incomplete.'); }

interface ParsedLink { readonly href: string; readonly title: string | null; readonly tag: string }
function links(input: string): ParsedLink[] { return [...input.matchAll(/<a\b([^>]*)>([\s\S]*?)<\/a>/giu)].flatMap((match) => { const href = attribute(match[1] ?? '', 'href'); return href === undefined ? [] : [{ href, title: textFromHtml(match[2] ?? ''), tag: match[1] ?? '' }]; }); }
function firstLink(input: string, pattern: RegExp) { return links(input).find((link) => pattern.test(link.href)); }
function captures(input: string, pattern: RegExp) { return [...input.matchAll(pattern)].flatMap((match) => match[1] === undefined ? [] : [match[1]]); }
function firstCapture(input: string, pattern: RegExp) { return input.match(pattern)?.[1] ?? null; }
function textFromMatch(input: string, pattern: RegExp) { const value = firstCapture(input, pattern); return value === null ? null : textFromHtml(value); }
function textFromHtml(value: string) { return text(decodeHtml(value.replace(/<script\b[\s\S]*?<\/script>/giu, '').replace(/<style\b[\s\S]*?<\/style>/giu, '').replace(/<[^>]+>/gu, ' '))); }
function text(value: string) { const normalized = value.replace(/\u00a0/gu, ' ').replace(/\s+/gu, ' ').trim(); return normalized === '' ? null : normalized; }
function attribute(tag: string, name: string) { const escaped = name.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&'); const match = tag.match(new RegExp(`\\b${escaped}\\s*=\\s*(["'])([\\s\\S]*?)\\1`, 'iu')); return match?.[2] === undefined ? undefined : decodeHtml(match[2]); }
function decodeHtml(input: string) { const named: Readonly<Record<string, string>> = { amp: '&', apos: "'", gt: '>', lt: '<', nbsp: ' ', quot: '"' }; return input.replace(/&(#(?:x[0-9a-f]+|\d+)|[a-z]+);/giu, (entity, body: string) => { const value = body.toLowerCase(); if (value.startsWith('#x')) return String.fromCodePoint(Number.parseInt(value.slice(2), 16)); if (value.startsWith('#')) return String.fromCodePoint(Number.parseInt(value.slice(1), 10)); return named[value] ?? entity; }); }
function isRecord(value: unknown): value is Record<string, unknown> { return typeof value === 'object' && value !== null && !Array.isArray(value); }
function stringValue(value: unknown): string | null { return typeof value === 'string' && value !== '' ? value : typeof value === 'number' && Number.isFinite(value) ? String(value) : null; }
