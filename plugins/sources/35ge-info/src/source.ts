/** 35中文网 parser and HTTP/resource boundary. Response bodies and user input are never logged. */
import { Buffer } from 'node:buffer';
import * as cheerio from 'cheerio/slim';

import type { ContentDetail, ContentSummary, MgReadPluginContext } from './contracts.js';

const origin = 'http://www.35ge.info';
export const categories = Object.freeze([
  ['fantasy', '玄幻魔法', '/xs/1-default-0-0-0-0-0-0-1.html'],
  ['wuxia', '武侠修真', '/xs/2-default-0-0-0-0-0-0-1.html'],
  ['urban', '都市言情', '/xs/3-default-0-0-0-0-0-0-1.html'],
  ['history', '历史军事', '/xs/4-default-0-0-0-0-0-0-1.html'],
  ['game', '游戏竞技', '/xs/5-default-0-0-0-0-0-0-1.html'],
  ['science-fiction', '科幻恐怖', '/xs/6-default-0-0-0-0-0-0-1.html'],
  ['other', '其他类型', '/xs/7-default-0-0-0-0-0-0-1.html'],
  ['completed', '完本小说', '/xs/0-default-0-0-0-0-2-0-1.html'],
] as const);

export class ThirtyFiveSource {
  constructor(private readonly context: MgReadPluginContext) {}

  async search(query: string): Promise<readonly ContentSummary[]> {
    const url = new URL('/modules/article/search.php', origin);
    url.searchParams.set('searchkey', query);
    const $ = cheerio.load(await this.#html(url));
    const items = this.#parseRows($, '.novelslist2 ul li', url, null);
    return this.#fillCovers(items);
  }

  async discover(categoryId: string, page: number): Promise<readonly ContentSummary[]> {
    const category = categories.find(([id]) => id === categoryId);
    if (category === undefined) throw new Error('Unknown category.');
    const path = category[2].replace(/-\d+\.html$/u, `-${page}.html`);
    const url = new URL(path, origin);
    const $ = cheerio.load(await this.#html(url));
    const selector = categoryId === 'completed' ? '#main div.topbooks ul li' : '#newscontent .l ul li';
    const items = this.#parseRows($, selector, url, category[1]);
    return this.#fillCovers(items);
  }

  async getDetail(id: string): Promise<ContentDetail> {
    const url = decodeBookId(id);
    const $ = cheerio.load(await this.#html(url));
    const title = meta($, 'og:novel:book_name') ?? clean($('#info h1').first().text());
    if (title === null) throw new Error('Detail title is missing.');
    const author = meta($, 'og:novel:author');
    const category = meta($, 'og:novel:category');
    const latestTitle = meta($, 'og:novel:latest_chapter_name');
    const latestRaw = meta($, 'og:novel:latest_chapter_url');
    const latestUrl = latestRaw === null ? null : new URL(latestRaw, url);
    const updatedAt = meta($, 'og:novel:update_time');
    const coverRaw = meta($, 'og:image');
    return Object.freeze({
      ...summary({
        url,
        title,
        author,
        coverUrl: coverRaw === null ? null : this.#proxyImage(new URL(coverRaw, url), url),
        description: normalizeIntro(clean($('#intro').first().text()) ?? meta($, 'og:description')),
        status: parseStatus(meta($, 'og:novel:status')),
        updatedAt,
        latestTitle,
        latestUrl,
        categories: category === null ? [] : [category],
      }),
      aliases: Object.freeze([]),
      catalogUrl: url.toString(),
    });
  }

  async getChapters(id: string) {
    const bookUrl = decodeBookId(id);
    const $ = cheerio.load(await this.#html(bookUrl));
    const headings = $('#list dl dt').toArray();
    const bodyHeading = headings.find((element) => /正文/u.test($(element).text()));
    if (bodyHeading === undefined) throw new Error('Catalog body section is missing.');
    const seen = new Set<string>();
    const chapters: Array<Readonly<Record<string, unknown>>> = [];
    $(bodyHeading).nextAll('dd').find('a[href]').each((_, element) => {
      const href = $(element).attr('href');
      const title = clean($(element).text());
      if (href === undefined || title === null) return;
      const chapterUrl = new URL(href, bookUrl);
      if (!sameBookChapter(chapterUrl, bookUrl) || seen.has(chapterUrl.pathname)) return;
      seen.add(chapterUrl.pathname);
      chapters.push(Object.freeze({
        id: encodeChapterId(chapterUrl), title, order: chapters.length, url: chapterUrl.toString(),
        volumeTitle: null, wordCount: null, updatedAt: null, isLocked: false, attributes: Object.freeze([]),
      }));
    });
    if (chapters.length === 0) throw new Error('Catalog is empty.');
    if (chapters.length > 5000) throw new Error('Catalog exceeds the Runtime chapter limit.');
    return Object.freeze({ items: Object.freeze(chapters) });
  }

  async getContent(id: string, chapterId: string) {
    const bookUrl = decodeBookId(id);
    const chapterUrl = decodeChapterId(chapterId, bookUrl);
    const $ = cheerio.load(await this.#html(chapterUrl));
    const content = $('#content').first();
    if (content.length === 0) throw new Error('Chapter content is missing.');
    let html = content.html() ?? '';
    html = html.replace(/<script[\s\S]*?<\/script>/giu, '');
    const paragraphs: string[] = [];
    for (const fragment of html.split(/<br\s*\/?>|<\/?p[^>]*>/giu)) {
      let line = clean(cheerio.load(`<div>${fragment}</div>`)('div').text());
      if (line === null) continue;
      line = line.replace(/[（(][^)）]*飞速小说网[^)）]*[)）]/giu, '')
        .replace(/飞速小说网\s*www[\s/／．.]*feisuxs\.com/giu, '')
        .replace(/chaptererror\s*\(\s*\)\s*;?/giu, '')
        .replace(/(?:本章未完|加入书签|章节报错|请收藏|最快更新|天才一秒记住|35中文网|35ge\.info)/giu, '')
        .trim();
      if (line !== '') paragraphs.push(line);
    }
    return Object.freeze({
      chapterId, contentKind: 'novel' as const, title: clean($('h1').first().text()), updatedAt: null,
      text: paragraphs.join('\n\n'), pages: Object.freeze([]),
    });
  }

  async resource(request: Record<string, unknown>) {
    if (request.kind !== 'image' || typeof request.url !== 'string' || typeof request.referer !== 'string') return emptyResource(400);
    const url = new URL(request.url); const referer = new URL(request.referer);
    if (url.origin !== origin || referer.origin !== origin) return emptyResource(400);
    const response = await this.context.http.fetch(url, { headers: { accept: 'image/*', referer: referer.toString() } });
    const body = new Uint8Array(await response.arrayBuffer());
    const type = response.headers.get('content-type');
    return Object.freeze({ status: response.status, headers: type === null ? {} : { 'content-type': type }, body });
  }

  #parseRows($: cheerio.CheerioAPI, selector: string, pageUrl: URL, fallbackCategory: string | null): readonly ContentSummary[] {
    const seen = new Set<string>(); const items: ContentSummary[] = [];
    for (const element of $(selector).toArray()) {
      const root = $(element);
      const link = root.find('.s2 a[href], a[href*="/xs/"]').first();
      const href = link.attr('href'); const title = clean(link.text());
      if (href === undefined || title === null) continue;
      const url = new URL(href, pageUrl);
      if (!isBookUrl(url) || seen.has(bookIdentity(url))) continue;
      seen.add(bookIdentity(url));
      const category = stripBrackets(clean(root.find('.s1').first().text())) ?? fallbackCategory;
      const latestLink = root.find('.s3 a[href]').first();
      const latestHref = latestLink.attr('href');
      items.push(summary({
        url, title, author: clean(root.find('.s4, .s5').last().text()), coverUrl: null, description: null,
        status: parseStatus(clean(root.find('.s7').first().text())), updatedAt: null,
        latestTitle: clean(latestLink.text()), latestUrl: latestHref === undefined ? null : new URL(latestHref, pageUrl),
        categories: category === null ? [] : [category],
      }));
    }
    return Object.freeze(items);
  }

  async #fillCovers(items: readonly ContentSummary[]): Promise<readonly ContentSummary[]> {
    const results = [...items]; let next = 0;
    const worker = async () => {
      for (;;) {
        const index = next; next += 1;
        const item = results[index]; if (item === undefined) return;
        try {
          const $ = cheerio.load(await this.#html(new URL(item.url)));
          const raw = meta($, 'og:image');
          if (raw !== null) results[index] = Object.freeze({ ...item, coverUrl: this.#proxyImage(new URL(raw, item.url), new URL(item.url)) });
        } catch { /* Cover enrichment is optional; the list item remains usable. */ }
      }
    };
    await Promise.all(Array.from({ length: Math.min(8, results.length) }, worker));
    return Object.freeze(results);
  }

  async #html(url: URL): Promise<string> {
    const response = await this.context.http.fetch(url, { headers: { accept: 'text/html,application/xhtml+xml', 'accept-language': 'zh-CN,zh;q=0.9', referer: `${origin}/` } });
    const body = await response.text();
    if (!response.ok || /(?:cf-challenge|cf-turnstile|Just a moment|Checking your browser|challenge-platform)/iu.test(body)) throw new Error('Source page is unavailable.');
    return body;
  }
  #proxyImage(url: URL, referer: URL): string | null { return url.origin === origin ? this.context.resource.proxy({ kind: 'image', url: url.toString(), referer: referer.toString() }) : null; }
}

function summary(input: { readonly url: URL; readonly title: string; readonly author: string | null; readonly coverUrl: string | null; readonly description: string | null; readonly status: ContentSummary['status']; readonly updatedAt: string | null; readonly latestTitle: string | null; readonly latestUrl: URL | null; readonly categories: readonly string[] }): ContentSummary {
  const latestValid = input.latestUrl !== null && sameBookChapter(input.latestUrl, input.url);
  return Object.freeze({
    id: encodeBookId(input.url), title: input.title, contentKind: 'novel', author: input.author, url: input.url.toString(),
    coverUrl: input.coverUrl, description: input.description, language: 'zh-CN', status: input.status, access: 'free',
    wordCount: null, chapterCount: null, publishedAt: null, updatedAt: input.updatedAt,
    latestChapter: input.latestTitle === null ? null : Object.freeze({ id: latestValid ? encodeChapterId(input.latestUrl!) : null, title: input.latestTitle, url: latestValid ? input.latestUrl!.toString() : null, updatedAt: input.updatedAt }),
    categories: Object.freeze(input.categories), tags: Object.freeze([]), attributes: Object.freeze([]),
  });
}
function meta($: cheerio.CheerioAPI, property: string): string | null { return clean($(`meta[property="${property}"]`).first().attr('content')); }
function encodeBookId(url: URL): string { return `book:${token(bookIdentity(url))}`; }
function encodeChapterId(url: URL): string { return `chapter:${token(url.pathname)}`; }
function token(value: string): string { return Buffer.from(value, 'utf8').toString('base64url'); }
function decodeBookId(id: string): URL {
  const value = /^book:([A-Za-z0-9_-]+)$/u.exec(id)?.[1]; if (value === undefined) throw new Error('Content ID is invalid.');
  const identity = Buffer.from(value, 'base64url').toString('utf8');
  if (!/^\/\d+\/\d+\/$/u.test(identity)) throw new Error('Content ID is invalid.');
  return new URL(`/xs${identity}`, origin);
}
function decodeChapterId(id: string, bookUrl: URL): URL {
  const value = /^chapter:([A-Za-z0-9_-]+)$/u.exec(id)?.[1]; if (value === undefined) throw new Error('Chapter ID is invalid.');
  const url = new URL(Buffer.from(value, 'base64url').toString('utf8'), origin);
  if (!sameBookChapter(url, bookUrl)) throw new Error('Chapter ID is invalid.');
  return url;
}
function isBookUrl(url: URL): boolean { return url.origin === origin && /^\/(?:xs\/)?\d+\/\d+\/?$/u.test(url.pathname); }
function bookIdentity(url: URL): string { const match = /^\/(?:xs\/)?(\d+\/\d+)\/?$/u.exec(url.pathname); return match?.[1] === undefined ? '' : `/${match[1]}/`; }
function sameBookChapter(chapter: URL, book: URL): boolean { const key = bookIdentity(book); return key !== '' && chapter.origin === origin && new RegExp(`^/xs?${key.replaceAll('/', '\\/')}\\d+\\.html$`, 'u').test(chapter.pathname); }
function normalizeIntro(value: string | null): string | null { return value === null ? null : clean(value.replace(/\\[nr]/gu, '').replace(/[\r\n\u2028\u2029]+/gu, ' ')); }
function clean(value: string | undefined): string | null { const result = value?.replace(/\s+/gu, ' ').trim() ?? ''; return result === '' ? null : result; }
function stripBrackets(value: string | null): string | null { return value === null ? null : clean(value.replace(/^\[|\]$/gu, '')); }
function parseStatus(value: string | null): ContentSummary['status'] { if (value === null) return 'unknown'; if (/(?:全本|完本|完结)/u.test(value)) return 'completed'; if (/连载/u.test(value)) return 'ongoing'; if (/(?:停更|暂停)/u.test(value)) return 'hiatus'; return 'unknown'; }
function emptyResource(status: number) { return Object.freeze({ status, headers: Object.freeze({}), body: new Uint8Array() }); }
