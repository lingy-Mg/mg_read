/** 当前 SSR 页面解析；只读取真实卡片、目录、正文与资源，不推导图片文件名或章节。 */
import { load } from 'cheerio';
import { base, clean, entry, resource, sitePath, type Entry } from './identity.js';
export type Item = Entry & { title: string; cover: string; author: string; description: string | null };
export function listing(html: string): Item[] {
  const $ = load(html), result = new Map<string, Item>();
  for (const node of $('main a.group[href]').toArray()) {
    const a = $(node), href = a.attr('href') ?? '';
    if (!/^\/(photo|fiction|video)\/[a-zA-Z0-9_-]+$/u.test(href)) continue;
    const e = entry(href), title = clean(a.find('.font-medium').first().text() ||
      a.find('span').filter((_, x) => /(?:^|\s)mt-2(?:\s|$)/u.test($(x).attr('class') ?? '')).first().text());
    if (!title) continue;
    result.set(e.path, { ...e, title: title.slice(0, 256), cover: a.find('img').first().attr('src') ?? '',
      author: '', description: null });
  }
  return [...result.values()];
}
export function nextPage(html: string, path: string): string | null {
  const $ = load(html), current = new URL(path, base);
  const match = /^(\/(?:photos|fictions|videos))(?:\/(\d+))?$/u.exec(current.pathname);
  const page = Number(match?.[2] ?? current.searchParams.get('page') ?? '1');
  for (const node of $('main a[href]').toArray()) {
    let candidate: URL;
    try { candidate = new URL($(node).attr('href')!, base); } catch { continue; }
    if (candidate.origin !== base) continue;
    if (match && candidate.pathname === `${match[1]}/${page + 1}` && candidate.search === current.search) return sitePath(candidate.href);
    if (candidate.pathname === current.pathname && Number(candidate.searchParams.get('page')) === page + 1) {
      const a = new URL(current), b = new URL(candidate); a.searchParams.delete('page'); b.searchParams.delete('page');
      if (a.searchParams.toString() === b.searchParams.toString()) return sitePath(candidate.href);
    }
  }
  return null;
}
export function searchLists(html: string, query: string) {
  const $ = load(html), paths = new Set<string>();
  for (const node of $('main a[href]').toArray()) {
    const u = new URL($(node).attr('href')!, base);
    if (u.origin === base && u.pathname === '/search' && u.searchParams.get('q') === query &&
        ['photo', 'fiction', 'video'].includes(u.searchParams.get('type') ?? '')) paths.add(sitePath(u.href));
  }
  return [...paths];
}
export function detail(html: string, e: Entry): Item {
  const $ = load(html), title = clean($('main h1').first().text());
  if (!title) throw new Error('Content detail is unavailable.');
  return { ...e, title: title.slice(0, 256), cover: $('meta[property="og:image"]').attr('content') ?? '',
    author: '', description: clean($('meta[property="og:description"]').attr('content') ?? '') || null };
}
export function fictionChapters(html: string, e: Entry) {
  const $ = load(html), result = new Map<string, string>();
  for (const node of $('main a[href]').toArray()) {
    const a = $(node), path = a.attr('href') ?? '';
    if (!path.startsWith(e.path + '/') || !/^\d+$/u.test(path.slice(e.path.length + 1))) continue;
    // The start-reading button repeats chapter one, but is not its title.
    if (!a.hasClass('flex') || !a.hasClass('py-3')) continue;
    const title = clean(a.text()); if (title) result.set(path, title.slice(0, 256));
  }
  if (result.size) return [...result].map(([path, title]) => ({ path, title }));
  if ($('article.reader .font-serif').text().trim()) return [{ path: e.path, title: '全文' }];
  throw new Error('Fiction catalog and inline text are unavailable.');
}
export function fictionText(html: string) {
  const $ = load(html), body = $('article.reader .font-serif').first().clone();
  body.find('script,style,nav,aside').remove(); body.find('br').replaceWith('\n');
  body.find('p,div').append('\n\n');
  const text = body.text().split(/\n/u).map(x => x.trim()).filter(Boolean).join('\n\n');
  if (!text) throw new Error('Fiction text is unavailable.');
  return { text, title: clean($('article.reader h1').first().text()).slice(0, 256) || null };
}
export function photoImages(html: string, e: Entry) {
  const $ = load(html), images = new Set<string>();
  for (const node of $('main img[src]').toArray()) {
    const url = new URL($(node).attr('src')!, base);
    if (url.hostname === 'img.xchina.io' && url.pathname.startsWith(`/photos/${e.nativeId}/`)) images.add(resource(url.href));
  }
  if (!images.size) throw new Error('Album images are unavailable.');
  return [...images];
}
export function videoUrl(html: string) {
  const $ = load(html), src = $('#video-player').attr('data-src') || $('main #player-box video').attr('src');
  if (!src) throw new Error('Video address is unavailable.');
  return resource(src);
}

/** Detect the site's published chapter-entry gate, not an empty chapter or login page. */
export function chapterGate(html: string, path: string) {
  const $ = load(html);
  return !$('article.reader .font-serif').text().trim() && $('main a.btn-primary[href]').toArray().some(x => $(x).attr('href') === path && clean($(x).text()).includes('继续看'));
}
