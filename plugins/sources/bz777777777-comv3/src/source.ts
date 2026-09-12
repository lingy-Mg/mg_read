/**
 * Bz777 source.
 *
 * Protected HTML uses one Runtime-owned WebView page. Requests run through the
 * page's same-origin fetch. The page stays hidden unless verification requires
 * user interaction, then hides again after success.
 */
import { Buffer } from 'node:buffer';
import * as cheerio from 'cheerio/slim';
import { PluginCache } from '@mgread/plugin-cache';
import type { MgReadPluginContext, PluginWebViewPage } from '@mgread/source-api';

type WebViewPage = PluginWebViewPage;
export type Context = MgReadPluginContext;

interface Summary {
  readonly id: string; readonly title: string; readonly contentKind: 'novel'; readonly author: string | null; readonly url: string; readonly coverUrl: string | null; readonly description: string | null; readonly language: 'zh-CN'; readonly status: 'ongoing' | 'completed' | 'unknown'; readonly access: 'free'; readonly wordCount: null; readonly chapterCount: number | null; readonly publishedAt: null; readonly updatedAt: null; readonly latestChapter: { readonly id: null; readonly title: string; readonly url: null; readonly updatedAt: null } | null; readonly categories: readonly string[]; readonly tags: readonly string[]; readonly attributes: readonly never[];
}

type BrowserStage = 'page_open' | 'ready' | 'initial_fetch' | 'verification' | 'retry_fetch' | 'response_validation';

const origin = 'https://www.bz777777777.com';
const browserTimeoutMs = 120000;
const listing = Object.freeze({ namespace: 'listing', staleAfterMs: 10 * 60 * 1000, serveStaleWhileRevalidate: true });
const detail = Object.freeze({ namespace: 'detail', staleAfterMs: 60 * 60 * 1000, allowStaleOnError: false });
const catalog = Object.freeze({ namespace: 'catalog', staleAfterMs: 60 * 60 * 1000, allowStaleOnError: false });

export const categories = Object.freeze([
  ['all', '全部', '0'], ['fantasy', '玄幻奇幻', '1'], ['martial', '仙侠武侠', '2'], ['city', '都市言情', '3'],
  ['history', '穿越历史', '4'], ['scifi', '科幻灵异', '5'], ['classic', '藏经阁', '6'], ['other', '其他类别', '7'],
] as const);

export class BzSource {
  readonly #cache: PluginCache;
  #pagePromise: Promise<WebViewPage> | undefined;
  #readyPromise: Promise<void> | undefined;
  #browserTail: Promise<void> = Promise.resolve();
  constructor(private readonly context: Context) { this.#cache = new PluginCache(context.cacheDir, { logger: context.log }); }

  async search(query: string) {
    const urls = [`/s.php?q=${encodeURIComponent(query)}`, `/search/?searchkey=${encodeURIComponent(query)}`, `/ss/?searchkey=${encodeURIComponent(query)}&submit=`];
    for (const path of urls) {
      const url = new URL(path, origin);
      const items = this.parseList(await this.#browser(url, 'GET', null), url);
      if (items.length > 0) return items;
    }
    const url = new URL('/s.php', origin);
    return this.parseList(await this.#browser(url, 'POST', `objectType=2&type=articlename&s=${encodeURIComponent(query)}`), url);
  }

  async discover(id: string, page: number) {
    const rule = categories.find(([key]) => key === id);
    if (rule === undefined) throw new Error('Unknown category.');
    const url = new URL(`/shuku/${rule[2]}-lastupdate-0-${page}.html`, origin);
    return this.parseList(await this.#cache.getOrFetchText(url, listing, () => this.#browser(url, 'GET', null)), url);
  }

  parseList(html: string, base: URL): readonly Summary[] {
    const $ = cheerio.load(html); const seen = new Set<string>(); const items: Summary[] = [];
    $('.book-all-list li.column-2,.column-list ul.list li,.bookbox,.result-item,.book-img-text li,.rank-list li,.list-group-item,ul.searchlist li').each((_, element) => {
      const root = $(element); const link = root.find('a.name,.name a,.right h4 a,.bookname a,h4 a,h3 a,a.book-name,.title a,a[href*="/book/"]').first(); const href = link.attr('href'); const title = clean(link.text());
      if (href === undefined || title === null) return;
      const url = new URL(href, base); if (!isBook(url) || seen.has(url.toString())) return; seen.add(url.toString());
      const image = root.find('img').first(); const coverRaw = image.attr('data-src') ?? image.attr('data-original') ?? image.attr('src'); const authorText = clean(root.find('a.author,.author,dt,.s4').first().text()); const author = clean(/作者[：:]?\s*(.+)$/u.exec(authorText ?? '')?.[1]) ?? authorText; const kind = clean(root.find('.cat,.s1').first().text()); const latest = clean(root.find('p.update a,.update a,.s3 a').first().text());
      items.push(summary(url, title, author, coverRaw === undefined ? null : this.#proxy(new URL(coverRaw, base), base), null, latest, kind === null ? [] : [kind]));
    });
    return Object.freeze(items);
  }

  async getDetail(id: string) {
    const url = decode(id, 'book'); const html = await this.#cache.getOrFetchText(url, detail, () => this.#browser(url, 'GET', null)); const $ = cheerio.load(html);
    const title = clean($('meta[property="og:novel:book_name"]').attr('content')) ?? clean($('meta[property="og:title"]').attr('content')) ?? clean($('#info h1,h1.bookname,h1').first().text()); if (title === null) throw new Error('Detail title is missing.');
    const info = clean($('#info,.bookinfo').first().text()) ?? ''; const author = clean($('meta[property="og:novel:author"]').attr('content')) ?? clean(/作者[：:]?\s*([^\s<&]+)/u.exec(info)?.[1]); const coverRaw = clean($('meta[property="og:image"]').attr('content')) ?? clean($('#fmimg img,.bookimg img,.zhutu img').first().attr('src')); const intro = clean($('meta[property="og:description"]').attr('content')) ?? clean($('#intro,.intro,.bookinfo').first().text()); const kind = clean($('meta[property="og:novel:category"]').attr('content')); const latest = clean($('meta[property="og:novel:latest_chapter_name"],meta[property="og:novel:lastest_chapter_name"]').first().attr('content'));
    return Object.freeze({ ...summary(url, title, author, coverRaw === null ? null : this.#proxy(new URL(coverRaw, url), url), intro, latest, kind === null ? [] : [kind]), aliases: Object.freeze([]), catalogUrl: url.toString() });
  }

  async chapters(id: string) {
    const first = decode(id, 'book'); const values: { id: string; title: string; order: number; url: string; volumeTitle: null; wordCount: null; updatedAt: null; isLocked: false; attributes: readonly never[] }[] = []; const seen = new Set<string>(); let url = first;
    for (let page = 0; page < 60; page += 1) { const html = await this.#cache.getOrFetchText(url, catalog, () => this.#browser(url, 'GET', null)); const $ = cheerio.load(html); const links = $('#list dd a,#chapterlist a,.chapterlist a,.chapter-list a,.listmain dd a,#catalog a,.directoryArea a').toArray(); for (const element of links) { const href = $(element).attr('href'); const title = clean($(element).text()); if (href === undefined || title === null) continue; const chapter = new URL(href, url); if (!isChapter(chapter) || seen.has(chapter.toString())) continue; seen.add(chapter.toString()); values.push({ id: `chapter:${token(chapter)}`, title, order: values.length, url: chapter.toString(), volumeTitle: null, wordCount: null, updatedAt: null, isLocked: false, attributes: Object.freeze([]) }); } const next = $('a').filter((_, element) => clean($(element).text()) === '下一页').first().attr('href'); if (next === undefined) break; const candidate = new URL(next, url); if (candidate.origin !== origin || candidate.toString() === url.toString()) break; url = candidate; }
    if (values.length === 0) throw new Error('Catalog is empty.'); return Object.freeze({ items: Object.freeze(values) });
  }

  async content(id: string, chapterId: string) {
    decode(id, 'book'); let url = decode(chapterId, 'chapter'); const lines: string[] = []; const seen = new Set<string>();
    for (let page = 0; page < 15 && !seen.has(url.toString()); page += 1) { seen.add(url.toString()); const html = await this.#browser(url, 'GET', null); const $ = cheerio.load(html); const root = $('.page-content,#chaptercontent,#content,.read-content,#chapterText,.chapter-content').first(); for (const paragraph of root.find('p').length > 0 ? root.find('p').toArray() : [root.get(0)].filter(Boolean)) { const line = clean($(paragraph!).text()); if (line !== null && !/(?:本章未完|加入书签|章节报错)/u.test(line)) lines.push(line); } const next = $('a').filter((_, element) => clean($(element).text()) === '下一页').first().attr('href'); if (next === undefined) break; const candidate = new URL(next, url); if (candidate.origin !== origin || candidate.toString() === url.toString()) break; url = candidate; }
    const text = lines.join('\n\n'); if (text === '') throw new Error('Chapter text is empty.'); return Object.freeze({ chapterId, contentKind: 'novel' as const, title: null, updatedAt: null, text, pages: Object.freeze([]) });
  }

  #browser(url: URL, method: 'GET' | 'POST', body: string | null) { const operation = this.#browserTail.then(() => this.#browserNow(url, method, body)); this.#browserTail = operation.then(() => undefined, () => undefined); return operation; }

  async #browserNow(url: URL, method: 'GET' | 'POST', body: string | null) {
    let stage: BrowserStage = 'page_open';
    try {
      const page = await this.#page(); stage = 'ready'; await this.#ready(page); stage = 'initial_fetch';
      let response = await this.#fetchWithDiagnostics(page, url, method, body, 'initial');
      if (needsVerification(response.status, response.body)) {
        this.context.log.warn('source_browser_verification_required'); this.#readyPromise = undefined; stage = 'verification';
        await this.#verify(page, method === 'GET' ? url : new URL(origin)); this.#readyPromise = Promise.resolve(); stage = 'retry_fetch';
        response = await this.#fetchWithDiagnostics(page, url, method, body, 'retry');
      }
      stage = 'response_validation';
      if (needsVerification(response.status, response.body)) this.#raiseAccessBlocked();
      if (response.status >= 400) throw new Error(`Browser request failed with status ${response.status}.`);
      if (typeof response.body !== 'string') throw new Error('Browser returned a non-text response.');
      if (isChallenge(response.body)) this.#raiseAccessBlocked();
      return response.body;
    } catch (error) { this.context.log.warn(`source_browser_failed_stage_${stage}`); throw error; }
  }

  async #page() { if (this.#pagePromise !== undefined) return this.#pagePromise; const pending = this.context.webview.open({ visible: false, timeoutMs: browserTimeoutMs }); this.#pagePromise = pending; try { return await pending; } catch (error) { if (this.#pagePromise === pending) this.#pagePromise = undefined; throw error; } }

  async #ready(page: WebViewPage) { if (this.#readyPromise !== undefined) return this.#readyPromise; const pending = this.#verify(page, new URL(origin)); this.#readyPromise = pending; try { await pending; } catch (error) { if (this.#readyPromise === pending) this.#readyPromise = undefined; throw error; } }

  async #verify(page: WebViewPage, url: URL) {
    this.context.log.info('source_browser_navigate_started'); await page.navigate(url.toString(), { timeoutMs: browserTimeoutMs }); this.context.log.info('source_browser_navigate_completed');
    let html = await page.getHtml({ timeoutMs: browserTimeoutMs });
    if (isChallenge(html)) {
      this.context.log.warn('source_browser_challenge_detected');
      try {
        await page.show({ timeoutMs: browserTimeoutMs });
        this.context.log.info('source_browser_verification_wait_started');
        await this.#waitForVerification(page);
      } catch (error) {
        this.#raiseAccessBlocked();
        throw error;
      }
      this.context.log.info('source_browser_verification_wait_completed');
      const current = new URL(await page.getUrl({ timeoutMs: browserTimeoutMs })); if (current.origin !== origin) throw new Error('Browser verification left the source origin.');
      html = await page.getHtml({ timeoutMs: browserTimeoutMs }); if (isChallenge(html)) this.#raiseAccessBlocked();
      await page.hide({ timeoutMs: browserTimeoutMs });
    }
  }

  #raiseAccessBlocked(): never {
    this.context.errors.raise({
      code: 'source_access_blocked',
      message: '访问异常，请完成来源页面的浏览器验证后重试。',
      annotation: '检测到来源的安全验证页面；请在来源页面完成验证，然后点击“刷新”。',
    });
  }

  async #waitForVerification(page: WebViewPage) {
    const deadline = Date.now() + browserTimeoutMs;
    while (Date.now() < deadline) {
      await delay(1000);
      if (!isChallenge(await page.getHtml({ timeoutMs: browserTimeoutMs }))) return;
    }
    throw new Error('Browser verification is incomplete.');
  }

  async #fetchWithDiagnostics(page: WebViewPage, url: URL, method: 'GET' | 'POST', body: string | null, attempt: 'initial' | 'retry') { this.context.log.info(`source_browser_${attempt}_fetch_started`); const response = await this.#fetch(page, url, method, body); this.context.log.info(`source_browser_${attempt}_fetch_completed_${statusClass(response.status)}`); return response; }

  #fetch(page: WebViewPage, url: URL, method: 'GET' | 'POST', body: string | null) { return page.fetch({ url: url.toString(), method, headers: method === 'POST' ? { 'content-type': 'application/x-www-form-urlencoded', accept: 'text/html' } : { accept: 'text/html' }, body, responseType: 'text', timeoutMs: browserTimeoutMs }); }

  #proxy(url: URL, referer: URL) { if (url.origin !== origin || referer.origin !== origin) throw new Error('Image URL is invalid.'); return this.context.resource.proxy({ kind: 'image', url: url.toString(), headers: { Accept: 'image/*', Referer: referer.toString() } }); }
}

function summary(url: URL, title: string, author: string | null, coverUrl: string | null, description: string | null, latest: string | null, categories: readonly string[]): Summary { return Object.freeze({ id: `book:${token(url)}`, title: title.replace(/^\s*\[[^\]]+\]\s*/u, ''), contentKind: 'novel', author, url: url.toString(), coverUrl, description, language: 'zh-CN', status: 'unknown', access: 'free', wordCount: null, chapterCount: null, publishedAt: null, updatedAt: null, latestChapter: latest === null ? null : { id: null, title: latest, url: null, updatedAt: null }, categories: Object.freeze(categories), tags: Object.freeze([]), attributes: Object.freeze([]) }); }
function token(url: URL) { return Buffer.from(`${url.pathname}${url.search}`, 'utf8').toString('base64url'); }
function decode(value: string, prefix: 'book' | 'chapter') { const match = new RegExp(`^${prefix}:([A-Za-z0-9_-]+)$`, 'u').exec(value); if (match?.[1] === undefined) throw new Error('Opaque ID is invalid.'); const url = new URL(Buffer.from(match[1], 'base64url').toString('utf8'), origin); if (prefix === 'book' ? !isBook(url) : !isChapter(url)) throw new Error('Opaque ID is invalid.'); return url; }
function isBook(url: URL) { return url.origin === origin && (/\/book\/\d+\/?$/u.test(url.pathname) || /\/\d+\/\d+\/?$/u.test(url.pathname)); }
function isChapter(url: URL) { return url.origin === origin && (/\/book\/\d+\/\d+\.html$/u.test(url.pathname) || /\/(?:xs|look)\/\d+\/\d+\.html$/u.test(url.pathname)); }
function clean(value: string | undefined) { const result = value?.replace(/\s+/gu, ' ').trim() ?? ''; return result === '' ? null : result; }
function isChallenge(body: string) { return /(?:cf-challenge|cf-turnstile|Just a moment|Checking your browser|challenge-platform)/iu.test(body); }
function needsVerification(status: number, body: unknown) { return status === 403 || status === 503 || (typeof body === 'string' && isChallenge(body)); }
function statusClass(status: number) { if (status >= 200 && status < 300) return '2xx'; if (status >= 300 && status < 400) return '3xx'; if (status >= 400 && status < 500) return '4xx'; if (status >= 500 && status < 600) return '5xx'; return 'other'; }
function delay(ms: number) { return new Promise<void>(resolve => setTimeout(resolve, ms)); }
