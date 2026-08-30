/** Plugin API v1 adapter for the repository source `35ge-info`. */
import type { ChaptersRequest, ContentReferenceRequest, ContentRequest, DiscoverRequest, MgReadPluginContext, SearchRequest, SearchSuggestionsRequest } from './contracts.js';
import { categories, ThirtyFiveSource } from './source.js';

let context: MgReadPluginContext | undefined;
let source: ThirtyFiveSource | undefined;

export async function activate(next: MgReadPluginContext): Promise<void> { context = next; next.log.info('source_activated'); }

export async function search(request: SearchRequest) {
  if (request.cursor !== null) throw new Error('Search cursor is unsupported.');
  return invoke('search', async (active) => Object.freeze({
    items: Object.freeze((await active.search(request.query)).slice(0, request.pageSize)),
    nextCursor: null,
    totalCount: null,
  }));
}

export async function discover(request: DiscoverRequest) {
  if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null) throw new Error('Initial discovery request is invalid.');
    const content = await invoke('discover_home', (active) => active.discover('fantasy', 1));
    return categoriesDocument(content.slice(0, Math.min(request.pageSize, 10)));
  }
  const match = /^category:([a-z-]+)$/u.exec(request.target);
  if (match?.[1] === undefined) throw new Error('Discovery target is invalid.');
  const categoryId = match[1];
  const page = cursorPage(request.cursor, `category:${categoryId}`);
  const content = await invoke('discover', (active) => active.discover(categoryId, page));
  const items = Object.freeze(content.slice(0, request.pageSize).map((value) => Object.freeze({ content: value, rank: null, metric: null, recommendation: null })));
  const collectionId = `category-books:${categoryId}`;
  const continuation = content.length > 0 && page < 50
    ? Object.freeze({ target: request.target, cursor: `category:${categoryId}:${page + 1}` })
    : null;
  if (request.collectionId !== null) {
    if (request.collectionId !== collectionId) throw new Error('Discovery collection is invalid.');
    return Object.freeze({ kind: 'append' as const, collectionId, items, continuation });
  }
  return Object.freeze({ kind: 'document' as const, document: { components: Object.freeze([{
    type: 'section' as const,
    id: `${collectionId}-section`,
    title: categories.find(([id]) => id === categoryId)?.[1] ?? '分类',
    subtitle: null,
    children: Object.freeze([{ type: 'contentCollection' as const, id: collectionId, layout: 'list' as const, items, continuation }]),
  }]) } });
}

export async function searchSuggestions(_request: SearchSuggestionsRequest) { return Object.freeze({ items: Object.freeze([]), nextCursor: null }); }
export async function getDetail(request: ContentReferenceRequest) { return invoke('get_detail', (active) => active.getDetail(request.id)); }
export async function getChapters(request: ChaptersRequest) { return invoke('get_chapters', (active) => active.getChapters(request.id)); }
export async function getContent(request: ContentRequest) { return invoke('get_content', (active) => active.getContent(request.id, request.chapterId)); }
export async function resource(request: Record<string, unknown>) { return invoke('resource', (active) => active.resource(request)); }

function categoriesDocument(content: readonly Awaited<ReturnType<ThirtyFiveSource['discover']>>[number][]) {
  const items = Object.freeze(content.map((value) => Object.freeze({ content: value, rank: null, metric: null, recommendation: null })));
  return Object.freeze({ kind: 'document' as const, document: { components: Object.freeze([
    ...(items.length === 0 ? [] : [{
      type: 'section' as const, id: 'featured-section', title: '站内精选', subtitle: '从玄幻魔法频道开始探索', icon: 'recommendation' as const,
      children: Object.freeze([{ type: 'contentCollection' as const, id: 'featured-books', layout: 'shelf' as const, items, continuation: null }]),
    }]),
    {
      type: 'section' as const, id: 'categories-section', title: '小说分类', subtitle: '按题材继续发现', icon: 'explore' as const,
      children: Object.freeze([{ type: 'categoryCollection' as const, id: 'categories', layout: 'chips' as const,
        categories: Object.freeze(categories.map(([id, title]) => Object.freeze({ id, title, target: `category:${id}`, count: null, url: null, icon: categoryIcon(id) }))),
      }]),
    },
  ]) } });
}
function categoryIcon(id: string) { return ({ fantasy: 'fantasy', wuxia: 'wuxia', urban: 'urban', history: 'history', game: 'game', 'science-fiction': 'scienceFiction', completed: 'completed' } as const)[id as 'fantasy'] ?? 'other'; }
function requireSource(): ThirtyFiveSource { if (context === undefined) throw new Error('Source is not activated.'); return source ??= new ThirtyFiveSource(context); }
async function invoke<T>(operation: string, action: (active: ThirtyFiveSource) => Promise<T>): Promise<T> {
  if (context === undefined) throw new Error('Source is not activated.');
  context.log.info(`source_${operation}_started`);
  try { const result = await action(requireSource()); context.log.info(`source_${operation}_completed`); return result; }
  catch (error) { context.log.warn(`source_${operation}_failed`); throw error; }
}
function cursorPage(cursor: string | null, scope: string): number {
  if (cursor === null) return 1;
  const escaped = scope.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&');
  const page = Number(new RegExp(`^${escaped}:(\\d+)$`, 'u').exec(cursor)?.[1]);
  if (!Number.isSafeInteger(page) || page < 2 || page > 50) throw new Error('Cursor is invalid.');
  return page;
}
