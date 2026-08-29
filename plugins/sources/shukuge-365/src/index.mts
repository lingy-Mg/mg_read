/** Plugin API v1 adapter for the repository source `shukuge-365`. */
import type {
  ChaptersRequest,
  ContentReferenceRequest,
  ContentRequest,
  DiscoverRequest,
  MgReadPluginContext,
  SearchRequest,
  SearchSuggestionsRequest,
} from './contracts.js';
import { categories, ShukugeSource } from './source.js';

let context: MgReadPluginContext | undefined;
let source: ShukugeSource | undefined;

export async function activate(next: MgReadPluginContext): Promise<void> {
  context = next;
  next.log.info('source_activated');
}

export async function search(request: SearchRequest) {
  return invoke('search', async (active) => {
    const page = cursorPage(request.cursor, 'search');
    const result = await active.search(request.query, page);
    return Object.freeze({
      items: Object.freeze(result.items.slice(0, request.pageSize)),
      nextCursor: result.hasNext ? `search:${page + 1}` : null,
      totalCount: result.totalCount,
    });
  });
}

export async function discover(request: DiscoverRequest) {
  if (request.target === null) return categoriesDocument();
  const match = /^category:([a-z-]+)$/u.exec(request.target);
  if (match?.[1] === undefined) throw new Error('Discovery target is invalid.');
  const categoryId = match[1];
  const page = cursorPage(request.cursor, `category:${categoryId}`);
  const result = await invoke('discover', (active) => active.discover(categoryId, page));
  const items = Object.freeze(result.items.slice(0, request.pageSize).map((content) => Object.freeze({
    content,
    rank: null,
    metric: null,
    recommendation: null,
  })));
  const collectionId = `category-books:${categoryId}`;
  const continuation = result.hasNext
    ? Object.freeze({ target: request.target, cursor: `category:${categoryId}:${page + 1}` })
    : null;
  if (request.collectionId !== null) {
    if (request.collectionId !== collectionId) throw new Error('Discovery collection is invalid.');
    return Object.freeze({ kind: 'append' as const, collectionId, items, continuation });
  }
  const title = categories.find(([id]) => id === categoryId)?.[1] ?? '分类';
  return Object.freeze({ kind: 'document' as const, document: { components: Object.freeze([{
    type: 'section' as const,
    id: `${collectionId}-section`,
    title,
    subtitle: null,
    children: Object.freeze([{
      type: 'contentCollection' as const,
      id: collectionId,
      layout: 'list' as const,
      items,
      continuation,
    }]),
  }]) } });
}

export async function searchSuggestions(_request: SearchSuggestionsRequest) {
  return Object.freeze({ items: Object.freeze([]), nextCursor: null });
}

export async function getDetail(request: ContentReferenceRequest) {
  return invoke('get_detail', (active) => active.getDetail(request.id));
}

export async function getChapters(request: ChaptersRequest) {
  return invoke('get_chapters', (active) => active.getChapters(request.id));
}

export async function getContent(request: ContentRequest) {
  return invoke('get_content', (active) => active.getContent(request.id, request.chapterId));
}

export async function resource(request: Record<string, unknown>) {
  return invoke('resource', (active) => active.resource(request));
}

function categoriesDocument() {
  return Object.freeze({ kind: 'document' as const, document: { components: Object.freeze([{
    type: 'section' as const,
    id: 'categories-section',
    title: '分类',
    subtitle: null,
    children: Object.freeze([{
      type: 'categoryCollection' as const,
      id: 'categories',
      layout: 'grid' as const,
      categories: Object.freeze(categories.map(([id, title]) => Object.freeze({
        id,
        title,
        target: `category:${id}`,
        count: null,
        url: null,
      }))),
    }]),
  }]) } });
}

function requireSource(): ShukugeSource {
  if (context === undefined) throw new Error('Source is not activated.');
  return source ??= new ShukugeSource(context);
}

async function invoke<T>(operation: string, action: (active: ShukugeSource) => Promise<T>): Promise<T> {
  if (context === undefined) throw new Error('Source is not activated.');
  context.log.info(`source_${operation}_started`);
  try {
    const result = await action(requireSource());
    context.log.info(`source_${operation}_completed`);
    return result;
  } catch (error) {
    context.log.warn(`source_${operation}_failed`);
    throw error;
  }
}

function cursorPage(cursor: string | null, scope: string): number {
  if (cursor === null) return 1;
  const escaped = scope.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&');
  const page = Number(new RegExp(`^${escaped}:(\\d+)$`, 'u').exec(cursor)?.[1]);
  if (!Number.isSafeInteger(page) || page < 2) throw new Error('Cursor is invalid.');
  return page;
}
