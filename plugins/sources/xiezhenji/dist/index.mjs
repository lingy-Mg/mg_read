/** Plugin API adapter for repository UUID `xiezhenji`. */
import { categories, XiezhenjiSource } from './source.js';
let context;
let source;
export async function activate(next) { context = next; next.log.info('source_activated'); }
export async function search(request) { const page = cursor(request.cursor, 'search'); const items = (await requireSource().search(request.query, page)).slice(0, request.pageSize); return Object.freeze({ items, nextCursor: items.length === request.pageSize ? `search:${page + 1}` : null, totalCount: null }); }
export async function discover(request) { if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null)
        throw new Error('Initial discovery request is invalid.');
    const content = (await requireSource().discover('home', 1)).slice(0, Math.min(request.pageSize, 10));
    return homeDocument(content);
} const match = /^category:([a-z-]+)$/u.exec(request.target); if (match?.[1] === undefined)
    throw new Error('Target is invalid.'); const page = cursor(request.cursor, `category:${match[1]}`); const items = (await requireSource().discover(match[1], page)).slice(0, request.pageSize).map((content) => Object.freeze({ content, rank: null, metric: null, recommendation: null })); const collectionId = `category-books:${match[1]}`; const continuation = items.length === request.pageSize ? Object.freeze({ target: request.target, cursor: `category:${match[1]}:${page + 1}` }) : null; if (request.collectionId !== null)
    return Object.freeze({ kind: 'append', collectionId, items: Object.freeze(items), continuation }); return Object.freeze({ kind: 'document', document: { components: Object.freeze([{ type: 'section', id: `${collectionId}-section`, title: categories.find(([id]) => id === match[1])?.[1] ?? '分类', subtitle: null, children: Object.freeze([{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items: Object.freeze(items), continuation }]) }]) } }); }
function homeDocument(content) { const items = Object.freeze(content.map(value => Object.freeze({ content: value, rank: null, metric: null, recommendation: null }))); return Object.freeze({ kind: 'document', document: { components: Object.freeze([...(items.length === 0 ? [] : [{ type: 'section', id: 'latest-section', title: '最新写真', subtitle: '首页新近发布图集', icon: 'newRelease', children: Object.freeze([{ type: 'contentCollection', id: 'latest-galleries', layout: 'coverGrid', items, continuation: null }]) }]), { type: 'section', id: 'categories-section', title: '写真分类', subtitle: '按主题或榜单继续发现', icon: 'explore', children: Object.freeze([{ type: 'categoryCollection', id: 'categories', layout: 'chips', categories: Object.freeze(categories.map(([id, title]) => Object.freeze({ id, title, target: `category:${id}`, count: null, url: null, icon: id === 'new' ? 'newRelease' : id === 'hot' ? 'hot' : id === 'daily' ? 'dailyRanking' : id === 'weekly' ? 'weeklyRanking' : id === 'monthly' ? 'monthlyRanking' : 'manga' }))) }]) }]) } }); }
export async function searchSuggestions() { return Object.freeze({ items: Object.freeze([]), nextCursor: null }); }
export async function getDetail(request) { return requireSource().detail(request.id); }
export async function getChapters(request) { return requireSource().chapters(request.id); }
export async function getContent(request) { return requireSource().content(request.id, request.chapterId); }
function requireSource() { if (context === undefined)
    throw new Error('Source is not activated.'); return source ??= new XiezhenjiSource(context); }
function cursor(value, scope) { if (value === null)
    return 1; const match = new RegExp(`^${scope.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&')}:(\\d+)$`, 'u').exec(value); const page = Number(match?.[1]); if (!Number.isSafeInteger(page) || page < 2)
    throw new Error('Cursor is invalid.'); return page; }
