/** Public Manwa category links and HTML cards. Paths are source-owned; browsing never exposes arbitrary URL targets. */
import { load } from 'cheerio';
import { rankings } from './discovery-ranking.js';
export function browsePath(target) {
    const raw = target.startsWith('browse:') ? target.slice(7) : '';
    if (!/^\/(?:cate(?:\/[a-z0-9-]+)?|rank|discover)\/?(?:\?[a-zA-Z0-9_=&%.-]+)?$/u.test(raw) || raw.length > 300)
        throw new Error('Discovery target is invalid.');
    return raw;
}
export function navigation(html) {
    const $ = load(html), seen = new Set();
    const categories = $('a[href]').toArray().flatMap(node => {
        const href = $(node).attr('href') ?? '', title = $(node).text().trim();
        try {
            browsePath('browse:' + href);
        }
        catch {
            return [];
        }
        if (!title || seen.has(href) || seen.size >= 80)
            return [];
        seen.add(href);
        if (/^\/rank\/?$/u.test(href))
            return rankings.map(([id, title]) => ({ id: 'rank:' + id, title, target: 'rank:' + id, count: null, url: null, icon: 'ranking' }));
        return [{ id: 'browse:' + href, title, target: 'browse:' + href, count: null, url: null, icon: 'manga' }];
    });
    const children = [];
    for (let offset = 0; offset < categories.length; offset += 32)
        children.push({ type: 'categoryCollection', id: 'manwa-site-links-' + offset, layout: 'chips', categories: categories.slice(offset, offset + 32) });
    return categories.length ? [{ type: 'section', id: 'manwa-site-navigation', title: '站点分类与排行', subtitle: null, children }] : [];
}
export function cards(html) {
    const $ = load(html), seen = new Set();
    return $('a[href]').toArray().flatMap(node => {
        const link = $(node), id = /^\/comic\/(\d+)$/u.exec(link.attr('href') ?? '')?.[1], title = link.find('.title').text().trim();
        if (!id || !title || seen.has(id))
            return [];
        seen.add(id);
        return [{ id, title, cover: link.find('.thumb_img[data-src]').attr('data-src') ?? '', tags: link.find('.badge span').toArray().map(node => $(node).text().trim()) }];
    });
}
