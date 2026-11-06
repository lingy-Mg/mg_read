/**
 * 爱丽丝书库的稳定路由、联动筛选与站点分页证明。
 *
 * 职责：校验不透明 target/cursor，并将分类和排序投影为官网已核实的路由。
 * 注意：原创是独立列表；仅更新/字数/人气支持分类联动，不构造官网没有的筛选维度。
 */
import * as cheerio from 'cheerio/slim';
const orders = Object.freeze([
    Object.freeze({ id: 'update_time', label: '按更新' }),
    Object.freeze({ id: 'word', label: '按字数' }),
    Object.freeze({ id: 'hits', label: '按人气' }),
]);
export function browseState(target, categories) {
    if (target === 'library:original')
        return { original: true, categoryId: null, order: 'default' };
    if (target === 'library:latest')
        return { original: false, categoryId: null, order: 'update_time' };
    const category = /^category:(\d+)$/u.exec(target);
    const combined = /^browse:(all|\d+):(update_time|word|hits)$/u.exec(target);
    const categoryId = category?.[1] ?? (combined?.[1] === 'all' ? null : combined?.[1]);
    if (categoryId === undefined || (categoryId !== null && !categories.some((entry) => entry.id === categoryId))) {
        throw new Error('Discovery browse target is invalid.');
    }
    return { original: false, categoryId, order: category === null ? combined[2] : 'default' };
}
export function browseTarget(state) {
    if (state.original)
        return 'library:original';
    if (state.categoryId !== null && state.order === 'default')
        return `category:${state.categoryId}`;
    if (state.categoryId === null && (state.order === 'default' || state.order === 'update_time'))
        return 'library:latest';
    return `browse:${state.categoryId ?? 'all'}:${state.order}`;
}
export function browsePath(state) {
    if (state.original)
        return '/original.html';
    if (state.categoryId !== null && state.order === 'default')
        return `/lists/${state.categoryId}.html`;
    return `/all${state.categoryId === null ? '' : `/id/${state.categoryId}`}/order/${state.order === 'default' ? 'update_time' : state.order}+desc.html`;
}
export function browseCollectionId(state) {
    if (state.original)
        return 'original-books';
    if (state.categoryId !== null && state.order === 'default')
        return `category-books:${state.categoryId}`;
    return `browse-books:${state.categoryId ?? 'all'}:${state.order}`;
}
export function browseFilters(state, categories) {
    const availableOrders = state.categoryId === null ? orders : [{ id: 'default', label: '官网默认' }, ...orders];
    return Object.freeze({
        type: 'filters', id: 'source-library-filters', resetTarget: 'library:latest',
        groups: Object.freeze([
            Object.freeze({
                id: 'category', label: '分类', selectedOptionId: state.categoryId ?? 'all',
                options: Object.freeze([{ id: 'all', title: '全部分类' }, ...categories].map((category) => Object.freeze({
                    id: category.id, label: category.title,
                    target: browseTarget({ ...state, categoryId: category.id === 'all' ? null : category.id }),
                    icon: 'category',
                }))),
            }),
            Object.freeze({
                id: 'order', label: '排序', selectedOptionId: state.order,
                options: Object.freeze(availableOrders.map((order) => Object.freeze({
                    id: order.id, label: order.label,
                    target: browseTarget({ ...state, order: order.id }),
                }))),
            }),
        ]),
    });
}
export function browseCursor(cursor, state) {
    if (cursor === null)
        return { page: 1, offset: 0 };
    const legacy = !state.original && state.order === 'default' ? /^category-page:(\d+)$/u.exec(cursor) : null;
    const match = /^browse-page:(\d+):(\d+)$/u.exec(cursor);
    const page = Number(legacy?.[1] ?? match?.[1]);
    const offset = legacy === null ? Number(match?.[2]) : 0;
    if (!Number.isSafeInteger(page) || page < 1 || !Number.isSafeInteger(offset) || offset < 0 || offset > 1000) {
        throw new Error('Discovery cursor is invalid.');
    }
    return { page, offset };
}
/** Only a real next-page anchor on this exact filtered route can advance the site page. */
export function browseNextPage(html, currentUrl, page) {
    const $ = cheerio.load(html);
    for (const element of $('.pagination a[href]').toArray()) {
        const href = $(element).attr('href');
        if (href === undefined)
            continue;
        let next;
        try {
            next = new URL(href, currentUrl);
        }
        catch {
            continue;
        }
        if (next.origin !== currentUrl.origin || next.pathname !== currentUrl.pathname || next.hash !== '')
            continue;
        if (next.searchParams.getAll('page').length !== 1 || next.searchParams.size !== 1)
            continue;
        if (next.searchParams.get('page') === String(page + 1))
            return page + 1;
    }
    return null;
}
