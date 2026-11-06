import { rankingRules } from './source-cache-policy.js';
import { discoveryMetric } from './source-parsing.js';
import { browseCollectionId, browseCursor, browseFilters, browseNextPage, browsePath, browseState, } from './source-browse-routes.js';
export async function discoverBrowse(request, dependencies) {
    const target = request.target;
    if (target === null)
        throw new Error('A browse target is required.');
    const ranking = target.startsWith('ranking:')
        ? rankingRules.find((entry) => `ranking:${entry.id}` === target)
        : undefined;
    if (target.startsWith('ranking:') && ranking === undefined)
        throw new Error('Ranking target is invalid.');
    const state = ranking === undefined ? browseState(target, dependencies.categories) : null;
    const collectionId = ranking === undefined ? browseCollectionId(state) : `ranking-books:${ranking.id}`;
    if ((request.collectionId !== null && (request.collectionId !== collectionId || request.cursor === null)) ||
        (ranking !== undefined && (request.collectionId !== null || request.cursor !== null))) {
        throw new Error('Discovery continuation is invalid.');
    }
    const { page, offset } = state === null ? { page: 1, offset: 0 } : browseCursor(request.cursor, state);
    if (!Number.isSafeInteger(request.pageSize) || request.pageSize < 1)
        throw new Error('Discovery page size is invalid.');
    const deadlineMs = Date.now() + 10_000;
    const pageUrl = new URL(ranking?.path ?? browsePath(state), dependencies.baseUrl);
    if (page > 1)
        pageUrl.searchParams.set('page', String(page));
    const html = await dependencies.getHtml(pageUrl);
    const allItems = await dependencies.parseList(html, pageUrl);
    if (offset > allItems.length)
        throw new Error('Discovery cursor exceeds the source page.');
    const pageSize = Math.min(request.pageSize, 50);
    // The fixed time-ranking pages are complete 50-row lists. Other pages are
    // sliced locally before advancing the real website page, including original.
    const selected = ranking === undefined ? allItems.slice(offset, offset + pageSize) : allItems;
    const visible = (await dependencies.hydrate(selected, ranking !== undefined, deadlineMs)).map(dependencies.proxy);
    const nextPage = ranking === undefined ? browseNextPage(html, pageUrl, page) : null;
    const nextOffset = offset + selected.length;
    const continuation = ranking !== undefined ? null
        : nextOffset < allItems.length
            ? Object.freeze({ target, cursor: `browse-page:${page}:${nextOffset}` })
            : nextPage === null ? null : Object.freeze({ target, cursor: `browse-page:${nextPage}:0` });
    const items = Object.freeze(visible.map((content) => Object.freeze({
        content, rank: null, metric: discoveryMetric(content), recommendation: null,
    })));
    if (request.collectionId !== null)
        return Object.freeze({ kind: 'append', collectionId, items, continuation });
    const title = ranking?.title ?? (state.original ? '原创专区' : state.categoryId === null
        ? '最新小说' : dependencies.categories.find((entry) => entry.id === state.categoryId).title);
    const components = [];
    if (state !== null && !state.original)
        components.push(browseFilters(state, dependencies.categories));
    components.push(Object.freeze({
        type: 'section', id: `source-results-section:${collectionId}`, title, subtitle: null,
        children: Object.freeze([Object.freeze({
                type: 'contentCollection', id: collectionId, layout: 'list', items, continuation,
            })]),
    }));
    return Object.freeze({ kind: 'document', document: Object.freeze({ components: Object.freeze(components) }) });
}
