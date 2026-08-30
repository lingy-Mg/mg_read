/** 365小说网 parser and HTTP/resource boundary. No response body or user input is logged. */
import { Buffer } from 'node:buffer';
import * as cheerio from 'cheerio/slim';

import type { ContentDetail, ContentSummary, MgReadPluginContext } from './contracts.js';

const origin = 'http://www.shukuge.com';
const maxCatalogPages = 50;
const maxChapterItems = 5000;

export const categories = Object.freeze([
  ['fantasy', '玄幻', '/i-xuanhuan/'], ['romance', '言情', '/i-yanqing/'],
  ['transmigration', '穿越', '/i-chuanyue/'], ['rebirth', '重生', '/i-chongsheng/'],
  ['alternate-history', '架空', '/i-jiakong/'], ['ceo', '总裁', '/i-zongcai/'],
  ['wuxia', '武侠', '/i-wuxia/'], ['xianxia', '仙侠', '/i-xianxia/'],
  ['danmei', '耽美', '/i-danmei/'], ['urban', '都市', '/i-dushi/'],
  ['military', '军事', '/i-junshi/'], ['game', '网游', '/i-wangyou/'],
  ['mystery', '悬疑', '/i-xuanyi/'], ['literature', '文学', '/i-wenxue/'],
  ['science-fiction', '科幻', '/i-kehuan/'], ['cultivation', '修真', '/i-xiuzhen/'],
  ['history', '历史', '/i-lishi/'], ['other', '其他', '/i-qita/'],
  ['new', '最新小说', '/new/'], ['ranking', '排行榜', '/top/'],
] as const);

interface ListingResult {
  readonly items: readonly ContentSummary[];
  readonly hasNext: boolean;
  readonly totalCount: number | null;
}

export class ShukugeSource {
  constructor(private readonly context: MgReadPluginContext) {}

  async search(query: string, page: number): Promise<ListingResult> {
    const url = new URL('/Search', origin);
    url.searchParams.set('wd', query);
    if (page > 1) url.searchParams.set('page', String(page));
    return this.parseList(await this.#html(url), url);
  }

  async discover(categoryId: string, page: number): Promise<ListingResult> {
    const category = categories.find(([id]) => id === categoryId);
    if (category === undefined) throw new Error('Unknown category.');
    const path = page === 1 ? category[2] : `${category[2].replace(/\/+$/u, '')}/${page}`;
    const url = new URL(path, origin);
    return this.parseList(await this.#html(url), url);
  }

  parseList(html: string, pageUrl: URL): ListingResult {
    const $ = cheerio.load(html);
    const seen = new Set<string>();
    const items: ContentSummary[] = [];
    $('.listitem').each((_, element) => {
      const root = $(element);
      const link = root.find('.bookdesc > a[href]').first();
      const href = link.attr('href');
      const title = clean(root.find('.bookdesc h2').first().text());
      if (href === undefined || title === null) return;
      const url = new URL(href, pageUrl);
      if (!isBookUrl(url) || seen.has(url.pathname)) return;
      seen.add(url.pathname);
      const spans = root.find('.bookdesc .sp span');
      const author = stripLabel(clean(spans.eq(0).text()), '作者');
      const category = stripLabel(clean(spans.eq(1).text()), '分类');
      const statusText = stripLabel(clean(spans.eq(2).text()), '状态');
      const latestLink = root.find('.bookdesc p.desc').first().find('a[href]').first();
      const latestTitle = clean(latestLink.text());
      const latestHref = latestLink.attr('href');
      const latestUrl = latestHref === undefined ? null : new URL(latestHref, pageUrl);
      const image = root.find('a.cover img').first().attr('src');
      const description = cleanDescription(root.find('.bookdesc p.desc').eq(1).text());
      items.push(summary({
        url,
        title,
        author,
        coverUrl: image === undefined ? null : this.#proxyImage(new URL(image, pageUrl), pageUrl),
        description,
        status: parseStatus(statusText),
        updatedAt: null,
        latestTitle,
        latestUrl,
        categories: category === null ? [] : [category],
      }));
    });
    const totalText = clean($('.panel-heading strong').first().text());
    const totalCount = parseInteger(/共\s*(\d+)/u.exec(totalText ?? '')?.[1]);
    return Object.freeze({
      items: Object.freeze(items),
      hasNext: $('a.next, .pagination a').toArray().some((element) => /下一页/u.test($(element).text())),
      totalCount,
    });
  }

  async getDetail(id: string): Promise<ContentDetail> {
    const url = decodeBookId(id);
    const $ = cheerio.load(await this.#html(url));
    const image = $('.bookdcover img').first();
    const title = clean(image.attr('alt')) ?? clean($('.bookd-title h1').first().text())?.replace(/\s*TXT全集\s*$/u, '') ?? null;
    if (title === null) throw new Error('Detail title is missing.');
    const more = $('.bookdmore p');
    const category = clean(more.eq(0).find('a').first().text());
    const author = clean(more.eq(2).find('a').first().text());
    const statusText = stripLabel(clean(more.eq(3).text()), '状态');
    const latest = more.eq(6).find('a').first();
    const updatedAt = stripLabel(clean(more.eq(7).text()), '最新时间');
    const coverRaw = image.attr('src');
    const catalogRaw = $('.bookdtext a.btn-primary[href*="/index.html"]').first().attr('href');
    if (catalogRaw === undefined) throw new Error('Detail catalog link is missing.');
    const catalogUrl = new URL(catalogRaw, url);
    if (!isCatalogUrl(catalogUrl, url)) throw new Error('Detail catalog link is invalid.');
    return Object.freeze({
      ...summary({
        url,
        title,
        author,
        coverUrl: coverRaw === undefined ? null : this.#proxyImage(new URL(coverRaw, url), url),
        description: cleanDescription($('.bookdtext > p').first().text()),
        status: parseStatus(statusText),
        updatedAt,
        latestTitle: clean(latest.text()),
        latestUrl: latest.attr('href') === undefined ? null : new URL(latest.attr('href')!, url),
        categories: category === null ? [] : [category],
      }),
      aliases: Object.freeze([]),
      catalogUrl: catalogUrl.toString(),
    });
  }

  async getChapters(id: string) {
    const bookUrl = decodeBookId(id);
    const catalogUrl = new URL('index.html', bookUrl);
    const firstHtml = await this.#html(catalogUrl);
    const $ = cheerio.load(firstHtml);
    const optionUrls = uniqueUrls($('option[value]').toArray().flatMap((element) => {
      const value = $(element).attr('value');
      if (value === undefined) return [];
      const url = new URL(value, catalogUrl);
      return isCatalogUrl(url, bookUrl) ? [url] : [];
    }));
    if (optionUrls.length > maxCatalogPages) throw new Error('Catalog page count exceeds the source limit.');
    const pages = optionUrls.length > 1
      ? await Promise.all(optionUrls.map((url) => url.toString() === catalogUrl.toString() ? firstHtml : this.#html(url)))
      : [firstHtml];
    const seen = new Set<string>();
    const chapters: Array<Readonly<Record<string, unknown>>> = [];
    for (const html of pages) {
      const page = cheerio.load(html);
      page('dl dd a[href]').each((_, element) => {
        const href = page(element).attr('href');
        const title = clean(page(element).text());
        if (href === undefined || title === null) return;
        const chapterUrl = new URL(href, catalogUrl);
        if (!isChapterUrl(chapterUrl, bookUrl) || seen.has(chapterUrl.pathname)) return;
        seen.add(chapterUrl.pathname);
        chapters.push(Object.freeze({
          id: encodeChapterId(chapterUrl),
          title,
          order: chapters.length,
          url: chapterUrl.toString(),
          volumeTitle: null,
          wordCount: null,
          updatedAt: null,
          isLocked: false,
          attributes: Object.freeze([]),
        }));
      });
    }
    if (chapters.length === 0) throw new Error('Catalog is empty.');
    if (chapters.length > maxChapterItems) throw new Error('Catalog exceeds the Runtime chapter limit.');
    return Object.freeze({ items: Object.freeze(chapters) });
  }

  async getContent(id: string, chapterId: string) {
    const bookUrl = decodeBookId(id);
    let url = decodeChapterId(chapterId, bookUrl);
    const visited = new Set<string>();
    const paragraphs: string[] = [];
    let title: string | null = null;
    for (let pageIndex = 0; pageIndex < 10 && !visited.has(url.toString()); pageIndex += 1) {
      visited.add(url.toString());
      const $ = cheerio.load(await this.#html(url));
      title ??= clean($('.bookd-title h1').first().text());
      const content = $('#content #content').first();
      if (content.length === 0) throw new Error('Chapter content is missing.');
      const html = content.html() ?? '';
      for (const fragment of html.split(/<br\s*\/?>|<\/?p[^>]*>/iu)) {
        const line = clean(cheerio.load(`<div>${fragment}</div>`)('div').text());
        if (line !== null && !/(?:本章未完|加入书签|章节报错|365小说网|shukuge\.com)/iu.test(line)) paragraphs.push(line);
      }
      const nextHref = $('a').filter((_, element) => clean($(element).text()) === '下一页').first().attr('href');
      if (nextHref === undefined || nextHref.startsWith('javascript:')) break;
      const next = new URL(nextHref, url);
      if (!isChapterPageContinuation(next, bookUrl, url)) break;
      url = next;
    }
    return Object.freeze({
      chapterId,
      contentKind: 'novel' as const,
      title,
      updatedAt: null,
      text: paragraphs.join('\n\n'),
      pages: Object.freeze([]),
    });
  }

  async #html(url: URL): Promise<string> {
    const response = await this.context.http.fetch(url, { headers: {
      accept: 'text/html,application/xhtml+xml',
      'accept-language': 'zh-CN,zh;q=0.9',
      referer: `${origin}/`,
    } });
    const body = await response.text();
    if (!response.ok || isChallenge(body)) throw new Error('Source page is unavailable.');
    return body;
  }

  #proxyImage(url: URL, referer: URL): string | null {
    if (url.origin !== origin) return null;
    return this.context.resource.proxy({ kind: 'image', url: url.toString(), headers: { Accept: 'image/*', Referer: referer.toString() } });
  }
}

function summary(input: {
  readonly url: URL;
  readonly title: string;
  readonly author: string | null;
  readonly coverUrl: string | null;
  readonly description: string | null;
  readonly status: ContentSummary['status'];
  readonly updatedAt: string | null;
  readonly latestTitle: string | null;
  readonly latestUrl: URL | null;
  readonly categories: readonly string[];
}): ContentSummary {
  const latestIsChapter = input.latestUrl !== null && isChapterUrl(input.latestUrl, input.url);
  return Object.freeze({
    id: encodeBookId(input.url),
    title: input.title,
    contentKind: 'novel',
    author: input.author,
    url: input.url.toString(),
    coverUrl: input.coverUrl,
    description: input.description,
    language: 'zh-CN',
    status: input.status,
    access: 'free',
    wordCount: null,
    chapterCount: null,
    publishedAt: null,
    updatedAt: input.updatedAt,
    latestChapter: input.latestTitle === null ? null : Object.freeze({
      id: latestIsChapter ? encodeChapterId(input.latestUrl!) : null,
      title: input.latestTitle,
      url: latestIsChapter ? input.latestUrl!.toString() : null,
      updatedAt: input.updatedAt,
    }),
    categories: Object.freeze(input.categories),
    tags: Object.freeze([]),
    attributes: Object.freeze([]),
  });
}

function encodeBookId(url: URL): string { return `book:${token(normalizeBookUrl(url).pathname)}`; }
function encodeChapterId(url: URL): string { return `chapter:${token(url.pathname)}`; }
function token(value: string): string { return Buffer.from(value, 'utf8').toString('base64url'); }
function decodeBookId(id: string): URL {
  const match = /^book:([A-Za-z0-9_-]+)$/u.exec(id);
  if (match?.[1] === undefined) throw new Error('Content ID is invalid.');
  const url = new URL(Buffer.from(match[1], 'base64url').toString('utf8'), origin);
  if (!isBookUrl(url)) throw new Error('Content ID is invalid.');
  return normalizeBookUrl(url);
}
function decodeChapterId(id: string, bookUrl: URL): URL {
  const match = /^chapter:([A-Za-z0-9_-]+)$/u.exec(id);
  if (match?.[1] === undefined) throw new Error('Chapter ID is invalid.');
  const url = new URL(Buffer.from(match[1], 'base64url').toString('utf8'), origin);
  if (!isChapterUrl(url, bookUrl)) throw new Error('Chapter ID is invalid.');
  return url;
}
function normalizeBookUrl(url: URL): URL { return new URL(url.pathname.replace(/\/?$/u, '/'), origin); }
function isBookUrl(url: URL): boolean { return url.origin === origin && /^\/book\/\d+\/?$/u.test(url.pathname); }
function isCatalogUrl(url: URL, bookUrl: URL): boolean { return url.origin === origin && url.pathname.startsWith(normalizeBookUrl(bookUrl).pathname) && /(?:index|index_\d+)\.html$/u.test(url.pathname); }
function isChapterUrl(url: URL, bookUrl: URL): boolean { return url.origin === origin && url.pathname.startsWith(normalizeBookUrl(bookUrl).pathname) && /^\/book\/\d+\/\d+\.html$/u.test(url.pathname); }
function isChapterPageContinuation(next: URL, bookUrl: URL, current: URL): boolean {
  if (next.origin !== origin || !next.pathname.startsWith(normalizeBookUrl(bookUrl).pathname)) return false;
  const currentChapter = /^(\/book\/\d+\/\d+)(?:_\d+)?\.html$/u.exec(current.pathname)?.[1];
  return currentChapter !== undefined && new RegExp(`^${currentChapter.replaceAll('/', '\\/')}(?:_\\d+)?\\.html$`, 'u').test(next.pathname);
}
function parseStatus(value: string | null): ContentSummary['status'] {
  if (value === null) return 'unknown';
  if (/(?:完结|完本|已完成)/u.test(value)) return 'completed';
  if (/(?:连载|在更)/u.test(value)) return 'ongoing';
  if (/(?:暂停|停更)/u.test(value)) return 'hiatus';
  return 'unknown';
}
function clean(value: string | undefined): string | null { const result = value?.replace(/\s+/gu, ' ').trim() ?? ''; return result === '' ? null : result; }
function stripLabel(value: string | null, label: string): string | null { return value === null ? null : clean(value.replace(new RegExp(`^${label}[：:]?\\s*`, 'u'), '')); }
function cleanDescription(value: string): string | null {
  const withoutPrefix = value.replace(/^简介[：:]?\s*/u, '').replace(/^[\s\S]*?下载后请在24小时之内删除[。.]?\s*/u, '');
  return clean(withoutPrefix);
}
function parseInteger(value: string | undefined): number | null { const number = Number(value); return Number.isSafeInteger(number) && number >= 0 ? number : null; }
function uniqueUrls(values: readonly URL[]): readonly URL[] { const seen = new Set<string>(); return values.filter((url) => { const key = url.toString(); if (seen.has(key)) return false; seen.add(key); return true; }); }
function isChallenge(body: string): boolean { return /(?:cf-challenge|cf-turnstile|Just a moment|Checking your browser|challenge-platform)/iu.test(body); }
