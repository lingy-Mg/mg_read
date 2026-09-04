import { ManhuaguiSource } from './source.js';
let context;
let source;
export async function activate(nextContext) { context = nextContext; source = new ManhuaguiSource(nextContext); nextContext.log.info('plugin_activated'); }
export async function discover(request) {
    return invoke('discover', async (active) => {
        if (request.target === null) {
            if (request.cursor !== null || request.collectionId !== null)
                throw new Error('Initial discovery request is invalid.');
            const home = await active.home(request.pageSize);
            return { kind: 'document', document: { components: [
                        { type: 'section', id: 'manhuagui-latest-section', title: '最新更新', subtitle: null, icon: 'newRelease', children: [
                                { type: 'contentCollection', id: 'manhuagui-latest', layout: 'coverGrid', items: home.items.map((content) => ({ content, rank: null, metric: null, recommendation: null })), continuation: null },
                            ] },
                        { type: 'section', id: 'manhuagui-categories-section', title: '漫画分类', subtitle: null, icon: 'category', children: [
                                { type: 'categoryCollection', id: 'manhuagui-categories', layout: 'chips', categories: active.categoryMetadata() },
                            ] },
                    ] } };
        }
        const result = await active.category(request.target, request.cursor, request.pageSize);
        if (request.collectionId !== null && request.collectionId !== result.collectionId)
            throw new Error('Discovery collection is invalid.');
        if (request.collectionId !== null)
            return { kind: 'append', collectionId: result.collectionId, items: result.items, continuation: result.continuation };
        return { kind: 'document', document: { components: [
                    { type: 'section', id: `${result.collectionId}-section`, title: result.title, subtitle: null, children: [
                            { type: 'contentCollection', id: result.collectionId, layout: 'coverGrid', items: result.items, continuation: result.continuation },
                        ] },
                ] } };
    });
}
export async function search(request) {
    return invoke('search', async (active) => {
        if (request.cursor !== null)
            throw new Error('Search cursor is not supported.');
        const items = await active.search(request.query, request.pageSize);
        return { items, nextCursor: null, totalCount: null };
    });
}
export async function searchSuggestions() { return { items: [], nextCursor: null }; }
export async function getDetail(request) { return invoke('get_detail', (active) => active.detail(request.id)); }
export async function getChapters(request) { return invoke('get_chapters', (active) => active.chapters(request.id)); }
export async function getContent(request) { return invoke('get_content', (active) => active.content(request.id, request.chapterId)); }
async function invoke(operation, action) {
    const activeContext = requireValue(context);
    const active = requireValue(source);
    activeContext.log.info(`source_${operation}_started`);
    try {
        const result = await action(active);
        activeContext.log.info(`source_${operation}_completed`);
        return result;
    }
    catch {
        activeContext.log.warn(`source_${operation}_failed`);
        throw new Error('Source operation failed.');
    }
}
function requireValue(value) { if (value === undefined)
    throw new Error('Source is not activated.'); return value; }
