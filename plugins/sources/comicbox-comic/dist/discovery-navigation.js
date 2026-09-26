/** ComicBox public filter groups. Parse observed dd controls; targets carry only bounded filter values, never remote URLs. */
import { load } from 'cheerio';
export const defaultFilters = { tag: '-1', area: '-1', end: '-1' };
export function filterTarget(value) { return 'browse:' + Buffer.from(JSON.stringify(value)).toString('base64url'); }
export function readFilters(target) {
    if (!/^browse:[A-Za-z0-9_-]{1,600}$/u.test(target))
        throw new Error('Discovery target is invalid.');
    let value;
    try {
        value = JSON.parse(Buffer.from(target.slice(7), 'base64url').toString('utf8'));
    }
    catch {
        throw new Error('Discovery target is invalid.');
    }
    if (!value || typeof value !== 'object')
        throw new Error('Discovery target is invalid.');
    const v = value;
    if (typeof v.tag !== 'string' || v.tag.length > 80 || !['-1', '1', '2'].includes(String(v.area)) || !['-1', '0', '1'].includes(String(v.end)))
        throw new Error('Discovery target is invalid.');
    return { tag: v.tag, area: String(v.area), end: String(v.end) };
}
export function filterSections(html, current) {
    const $ = load(html);
    return $('.sp-filter-group').toArray().flatMap((element, index) => {
        const group = $(element), title = group.find('.sp-filter-label').first().text().trim();
        const categories = group.find('dd[data-val]').toArray().flatMap(node => {
            const item = $(node), value = item.attr('data-val'), label = item.text().trim();
            const key = /active\(this,['"](tag|area|end)['"]\)/u.exec(item.attr('onclick') ?? '')?.[1];
            if (!key || !label || value === undefined || value.length > 80)
                return [];
            const target = filterTarget({ ...current, [key]: value });
            try {
                readFilters(target);
            }
            catch {
                return [];
            }
            return [{ id: target, title: label, target, count: null, url: null, icon: 'manga' }];
        });
        if (!title || categories.length === 0)
            return [];
        const children = [];
        for (let offset = 0; offset < categories.length; offset += 32)
            children.push({ type: 'categoryCollection', id: 'comicbox-filter-list-' + index + '-' + offset, layout: 'chips', categories: categories.slice(offset, offset + 32) });
        return [{ type: 'section', id: 'comicbox-filter-' + index, title, subtitle: null, icon: 'category', children }];
    });
}
export function hasNextPage(html, page) {
    const $ = load(html);
    return $('.pagination a[href]').toArray().some(node => {
        try {
            return Number(new URL($(node).attr('href'), 'https://www.comicbox.xyz').searchParams.get('page')) === page + 1;
        }
        catch {
            return false;
        }
    });
}
