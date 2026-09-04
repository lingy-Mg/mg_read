import { categories, Xiezhenji2Source } from './source.js';
let context;
let source;
export async function activate(next) { context = next; next.log.info('source_activated'); }
export async function search(request) { return invoke('search', async (active) => { const page = cursorPage(request.cursor, 'search'); const items = (await active.search(request.query, page)).slice(0, request.pageSize); return Object.freeze({ items, nextCursor: items.length === request.pageSize ? `search:${page + 1}` : null, totalCount: null }); }); }
export async function discover(request) { if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null)
        throw new Error('Initial discovery request is invalid.');
    const content = (await invoke('discover_home', (active) => active.discover('home', 1))).slice(0, Math.min(request.pageSize, 10));
    return homeDocument(content);
} const match = /^category:([a-z-]+)$/u.exec(request.target); if (match?.[1] === undefined)
    throw new Error('Discovery target is invalid.'); const page = cursorPage(request.cursor, `category:${match[1]}`); const items = (await requireSource().discover(match[1], page)).slice(0, request.pageSize).map((content) => Object.freeze({ content, rank: null, metric: null, recommendation: null })); const collectionId = `category-books:${match[1]}`; const continuation = items.length === request.pageSize ? Object.freeze({ target: request.target, cursor: `category:${match[1]}:${page + 1}` }) : null; if (request.collectionId !== null)
    return Object.freeze({ kind: 'append', collectionId, items: Object.freeze(items), continuation }); return Object.freeze({ kind: 'document', document: { components: Object.freeze([{ type: 'section', id: `${collectionId}-section`, title: categories.find(([id]) => id === match[1])?.[1] ?? '分类', subtitle: null, children: Object.freeze([{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items: Object.freeze(items), continuation }]) }]) } }); }
export async function searchSuggestions(_request) { return Object.freeze({ items: Object.freeze([]), nextCursor: null }); }
export async function getDetail(request) { return invoke('get_detail', (active) => active.getDetail(request.id)); }
export async function getChapters(request) { return invoke('get_chapters', async (active) => active.getChapters(request.id)); }
export async function getContent(request) { return invoke('get_content', (active) => active.getContent(request.id, request.chapterId)); }
function homeDocument(content) { const items = Object.freeze(content.map(value => Object.freeze({ content: value, rank: null, metric: null, recommendation: null }))); return Object.freeze({ kind: 'document', document: { components: Object.freeze([...(items.length === 0 ? [] : [{ type: 'section', id: 'latest-section', title: 'Cosplay 精选', subtitle: '首页新近发布图集', icon: 'newRelease', children: Object.freeze([{ type: 'contentCollection', id: 'latest-galleries', layout: 'coverGrid', items, continuation: null }]) }]), { type: 'section', id: 'categories-section', title: '写真分类', subtitle: '按主题或时段继续发现', icon: 'explore', children: Object.freeze([{ type: 'categoryCollection', id: 'categories', layout: 'chips', categories: Object.freeze(categories.map(([id, title]) => Object.freeze({ id, title, target: `category:${id}`, count: null, url: null, icon: id === 'day' ? 'dailyRanking' : id === 'three-day' ? 'trending' : id === 'week' ? 'weeklyRanking' : id === 'best' ? 'star' : 'manga' }))) }]) }]) } }); }
function requireSource() { if (context === undefined)
    throw new Error('Source is not activated.'); return source ??= new Xiezhenji2Source(context); }
async function invoke(operation, action) { if (context === undefined)
    throw new Error('Source is not activated.'); context.log.info(`source_${operation}_started`); try {
    const result = await action(requireSource());
    context.log.info(`source_${operation}_completed`);
    return result;
}
catch (error) {
    context.log.warn(`source_${operation}_failed`);
    throw error;
} }
function cursorPage(cursor, scope) { if (cursor === null)
    return 1; const match = new RegExp(`^${scope.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&')}:(\\d+)$`, 'u').exec(cursor); const page = Number(match?.[1]); if (!Number.isSafeInteger(page) || page < 2)
    throw new Error('Cursor is invalid.'); return page; }
