/** Plugin API v1 adapter for the repository source `baozimh-com`. */
import type { ChaptersRequest, ContentReferenceRequest, ContentRequest, DiscoverRequest, MgReadPluginContext, SearchRequest, SearchSuggestionsRequest } from './contracts.js';
import { categories, BaozimhSource } from './source.js';

let context: MgReadPluginContext | undefined;
let source: BaozimhSource | undefined;
export async function activate(next: MgReadPluginContext): Promise<void> { context = next; next.log.info('source_activated'); }
export async function search(request: SearchRequest) {
  if (request.cursor !== null) throw new Error('Search cursor is unsupported.');
  return invoke('search', async (active) => Object.freeze({ items: Object.freeze((await active.search(request.query)).slice(0, request.pageSize)), nextCursor: null, totalCount: null }));
}
export async function discover(request: DiscoverRequest) {
  if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null) throw new Error('Initial discovery request is invalid.');
    const content = await invoke('discover_home', (active) => active.discover('china'));
    return categoriesDocument(content.slice(0, Math.min(request.pageSize, 10)));
  }
  if (request.cursor !== null) throw new Error('Discovery cursor is unsupported.');
  const categoryId = /^category:([a-z-]+)$/u.exec(request.target)?.[1];
  if (categoryId === undefined) throw new Error('Discovery target is invalid.');
  if (request.collectionId !== null) throw new Error('Discovery continuation is unsupported.');
  const content = await invoke('discover', (active) => active.discover(categoryId));
  const items = Object.freeze(content.slice(0, request.pageSize).map((value) => Object.freeze({ content: value, rank: null, metric: null, recommendation: null })));
  const collectionId = `category-books:${categoryId}`;
  return Object.freeze({ kind: 'document' as const, document: { components: Object.freeze([{
    type: 'section' as const, id: `${collectionId}-section`, title: categories.find(([id]) => id === categoryId)?.[1] ?? '分类', subtitle: null,
    children: Object.freeze([{ type: 'contentCollection' as const, id: collectionId, layout: 'coverGrid' as const, items, continuation: null }]),
  }]) } });
}
export async function searchSuggestions(_request: SearchSuggestionsRequest) { return Object.freeze({ items: Object.freeze([]), nextCursor: null }); }
export async function getDetail(request: ContentReferenceRequest) { return invoke('get_detail', (active) => active.getDetail(request.id)); }
export async function getChapters(request: ChaptersRequest) { return invoke('get_chapters', (active) => active.getChapters(request.id)); }
export async function getContent(request: ContentRequest) { return invoke('get_content', (active) => active.getContent(request.id, request.chapterId)); }
export async function resource(request: Record<string, unknown>) { return invoke('resource', (active) => active.resource(request)); }
function categoriesDocument(content: readonly Awaited<ReturnType<BaozimhSource['discover']>>[number][]) { const items = Object.freeze(content.map((value) => Object.freeze({ content: value, rank: null, metric: null, recommendation: null }))); return Object.freeze({ kind: 'document' as const, document: { components: Object.freeze([...(items.length === 0 ? [] : [{ type: 'section' as const, id: 'featured-section', title: '国漫推荐', subtitle: '国漫频道新近作品', icon: 'manga' as const, children: Object.freeze([{ type: 'contentCollection' as const, id: 'featured-manga', layout: 'coverGrid' as const, items, continuation: null }]) }]), { type: 'section' as const, id: 'categories-section', title: '漫画分类', subtitle: '按地区或题材继续发现', icon: 'explore' as const, children: Object.freeze([{ type: 'categoryCollection' as const, id: 'categories', layout: 'chips' as const, categories: Object.freeze(categories.map(([id, title]) => Object.freeze({ id, title, target: `category:${id}`, count: null, url: null, icon: id === 'romance' ? 'romance' : id === 'action' ? 'hot' : id === 'fantasy' ? 'fantasy' : 'manga' }))) }]) }]) } }); }
function requireSource(): BaozimhSource { if (context === undefined) throw new Error('Source is not activated.'); return source ??= new BaozimhSource(context); }
async function invoke<T>(operation: string, action: (active: BaozimhSource) => Promise<T>): Promise<T> { if (context === undefined) throw new Error('Source is not activated.'); context.log.info(`source_${operation}_started`); try { const result = await action(requireSource()); context.log.info(`source_${operation}_completed`); return result; } catch (error) { context.log.warn(`source_${operation}_failed`); throw error; } }
