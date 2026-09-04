/** Plugin API adapter and source-owned discovery composition for 66manhua.cc. */
import { ManhuaSource } from './source.js';
let context;
let source;
// Discovery cover URLs are Runtime-owned, self-contained proxy URLs. Keep all
// homepage sections while leaving enough room under the public inline-result
// budget for those URLs and normal upstream title/description variation.
const discoveryItemLimits = Object.freeze({
    completed: 8,
    featured: 6,
    popular: 8,
    ranking: 4,
    recent: 8,
    rising: 8,
});
export async function activate(next) { context = next; next.log.info('source_activated'); }
export async function search(request) { rejectCursor(request.cursor); const items = (await requireSource().search(request.query)).slice(0, request.pageSize); return Object.freeze({ items, nextCursor: null, totalCount: null }); }
export async function discover(request) {
    if (request.target !== null || request.collectionId !== null)
        throw new Error('Discovery target is invalid.');
    rejectCursor(request.cursor);
    const home = await requireSource().discover();
    const components = [];
    addCollection(components, home.featured, request.pageSize, discoveryItemLimits.featured, 'featured', '精选推荐', '官网精选内容', 'recommendation', 'carousel');
    addCollection(components, home.recent, request.pageSize, discoveryItemLimits.recent, 'recent', '最近更新', '追踪最新章节', 'newRelease', 'coverGrid');
    const trendSections = [];
    addRankedCollection(trendSections, home.rising, request.pageSize, discoveryItemLimits.rising, 'rising', '上升最快', '近期热度增长最快', 'trending', 'compact');
    addRankedCollection(trendSections, home.popular, request.pageSize, discoveryItemLimits.popular, 'popular', '人气排行榜', '站内人气作品', 'hot', 'compact');
    if (trendSections.length !== 0)
        components.push(Object.freeze({ type: 'group', id: 'trend-group', layout: 'vertical', children: Object.freeze(trendSections) }));
    addCollection(components, home.completed, request.pageSize, discoveryItemLimits.completed, 'completed', '完结大作', '一次读到结局', 'completed', 'shelf');
    const rankingSections = [];
    for (const ranking of home.rankings)
        addRankedCollection(rankingSections, ranking.items, request.pageSize, discoveryItemLimits.ranking, ranking.id, ranking.title, null, 'ranking', 'compact');
    if (rankingSections.length !== 0)
        components.push(Object.freeze({ type: 'group', id: 'ranking-group', layout: 'vertical', children: Object.freeze(rankingSections) }));
    return Object.freeze({ kind: 'document', document: Object.freeze({ components: Object.freeze(components) }) });
}
export async function searchSuggestions() { return Object.freeze({ items: Object.freeze([]), nextCursor: null }); }
export async function getDetail(request) { return requireSource().detail(request.id); }
export async function getChapters(request) { return requireSource().chapters(request.id); }
export async function getContent(request) { return requireSource().content(request.id, request.chapterId); }
function requireSource() { if (context === undefined)
    throw new Error('Source is not activated.'); return source ??= new ManhuaSource(context); }
function rejectCursor(cursor) { if (cursor !== null)
    throw new Error('Cursor is invalid.'); }
function addCollection(components, contents, pageSize, maximumItems, id, title, subtitle, icon, layout) {
    if (contents.length === 0)
        return;
    const items = contents.slice(0, Math.min(pageSize, maximumItems)).map((content) => Object.freeze({ content, rank: null, metric: null, recommendation: null }));
    components.push(section(id, title, subtitle, icon, layout, items));
}
function addRankedCollection(components, contents, pageSize, maximumItems, id, title, subtitle, icon, layout) {
    if (contents.length === 0)
        return;
    const items = contents.slice(0, Math.min(pageSize, maximumItems)).map((item) => Object.freeze({ ...item, recommendation: null }));
    components.push(section(id, title, subtitle, icon, layout, items));
}
function section(id, title, subtitle, icon, layout, items) { return Object.freeze({ type: 'section', id: `${id}-section`, title, subtitle, icon, children: Object.freeze([{ type: 'contentCollection', id: `${id}-items`, layout, items: Object.freeze(items), continuation: null }]) }); }
