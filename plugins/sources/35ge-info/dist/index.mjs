import { categories, ThirtyFiveSource } from './source.js';
let context;
let source;
export async function activate(next) { context = next; next.log.info('source_activated'); }
export async function search(request) {
    if (request.cursor !== null)
        throw new Error('Search cursor is unsupported.');
    return invoke('search', async (active) => Object.freeze({
        items: Object.freeze((await active.search(request.query)).slice(0, request.pageSize)),
        nextCursor: null,
        totalCount: null,
    }));
}
export async function discover(request) {
    if (request.target === null) {
        if (request.cursor !== null || request.collectionId !== null)
            throw new Error('Initial discovery request is invalid.');
        const content = await invoke('discover_home', (active) => active.discover('fantasy', 1));
        return categoriesDocument(content.slice(0, Math.min(request.pageSize, 10)));
    }
    const match = /^category:([a-z-]+)$/u.exec(request.target);
    if (match?.[1] === undefined)
        throw new Error('Discovery target is invalid.');
    const categoryId = match[1];
    const page = cursorPage(request.cursor, `category:${categoryId}`);
    const content = await invoke('discover', (active) => active.discover(categoryId, page));
    const items = Object.freeze(content.slice(0, request.pageSize).map((value) => Object.freeze({ content: value, rank: null, metric: null, recommendation: null })));
    const collectionId = `category-books:${categoryId}`;
    const continuation = content.length > 0 && page < 50
        ? Object.freeze({ target: request.target, cursor: `category:${categoryId}:${page + 1}` })
        : null;
    if (request.collectionId !== null) {
        if (request.collectionId !== collectionId)
            throw new Error('Discovery collection is invalid.');
        return Object.freeze({ kind: 'append', collectionId, items, continuation });
    }
    return Object.freeze({ kind: 'document', document: { components: Object.freeze([{
                    type: 'section',
                    id: `${collectionId}-section`,
                    title: categories.find(([id]) => id === categoryId)?.[1] ?? '分类',
                    subtitle: null,
                    children: Object.freeze([{ type: 'contentCollection', id: collectionId, layout: 'list', items, continuation }]),
                }]) } });
}
export async function searchSuggestions(_request) { return Object.freeze({ items: Object.freeze([]), nextCursor: null }); }
export async function getDetail(request) { return invoke('get_detail', (active) => active.getDetail(request.id)); }
export async function getChapters(request) { return invoke('get_chapters', (active) => active.getChapters(request.id)); }
export async function getContent(request) { return invoke('get_content', (active) => active.getContent(request.id, request.chapterId)); }
function categoriesDocument(content) {
    const items = Object.freeze(content.map((value) => Object.freeze({ content: value, rank: null, metric: null, recommendation: null })));
    return Object.freeze({ kind: 'document', document: { components: Object.freeze([
                ...(items.length === 0 ? [] : [{
                        type: 'section', id: 'featured-section', title: '站内精选', subtitle: '从玄幻魔法频道开始探索', icon: 'recommendation',
                        children: Object.freeze([{ type: 'contentCollection', id: 'featured-books', layout: 'shelf', items, continuation: null }]),
                    }]),
                {
                    type: 'section', id: 'categories-section', title: '小说分类', subtitle: '按题材继续发现', icon: 'explore',
                    children: Object.freeze([{ type: 'categoryCollection', id: 'categories', layout: 'chips',
                            categories: Object.freeze(categories.map(([id, title]) => Object.freeze({ id, title, target: `category:${id}`, count: null, url: null, icon: categoryIcon(id) }))), }]),
                },
            ]) } });
}
function categoryIcon(id) { return { fantasy: 'fantasy', wuxia: 'wuxia', urban: 'urban', history: 'history', game: 'game', 'science-fiction': 'scienceFiction', completed: 'completed' }[id] ?? 'other'; }
function requireSource() { if (context === undefined)
    throw new Error('Source is not activated.'); return source ??= new ThirtyFiveSource(context); }
async function invoke(operation, action) {
    if (context === undefined)
        throw new Error('Source is not activated.');
    context.log.info(`source_${operation}_started`);
    try {
        const result = await action(requireSource());
        context.log.info(`source_${operation}_completed`);
        return result;
    }
    catch (error) {
        context.log.warn(`source_${operation}_failed`);
        throw error;
    }
}
function cursorPage(cursor, scope) {
    if (cursor === null)
        return 1;
    const escaped = scope.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&');
    const page = Number(new RegExp(`^${escaped}:(\\d+)$`, 'u').exec(cursor)?.[1]);
    if (!Number.isSafeInteger(page) || page < 2 || page > 50)
        throw new Error('Cursor is invalid.');
    return page;
}
