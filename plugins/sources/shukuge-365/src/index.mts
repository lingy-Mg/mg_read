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
  if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null) throw new Error('Initial discovery request is invalid.');
    const result = await invoke('discover_home', (active) => active.discover('new', 1));
    return categoriesDocument(result.items.slice(0, Math.min(request.pageSize, 10)));
  }
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

function categoriesDocument(content: readonly Awaited<ReturnType<ShukugeSource['discover']>>['items'][number][]) {
  const items = Object.freeze(content.map((value) => Object.freeze({ content: value, rank: null, metric: null, recommendation: null })));
  return Object.freeze({ kind: 'document' as const, document: { components: Object.freeze([
    ...(items.length === 0 ? [] : [{ type: 'section' as const, id: 'latest-section', title: '最新小说', subtitle: '官网最新入库作品', icon: 'newRelease' as const,
      children: Object.freeze([{ type: 'contentCollection' as const, id: 'latest-books', layout: 'shelf' as const, items, continuation: null }]) }]),
    { type: 'section' as const, id: 'categories-section', title: '探索分类', subtitle: '按题材继续发现', icon: 'explore' as const,
      children: Object.freeze([{ type: 'categoryCollection' as const, id: 'categories', layout: 'chips' as const,
        categories: Object.freeze(categories.map(([id, title]) => Object.freeze({ id, title, target: `category:${id}`, count: null, url: null, icon: categoryIcon(id) }))) }]) },
  ]) } });
}
function categoryIcon(id: string) { return ({ fantasy: 'fantasy', romance: 'romance', wuxia: 'wuxia', xianxia: 'wuxia', urban: 'urban', military: 'military', game: 'game', mystery: 'mystery', 'science-fiction': 'scienceFiction', history: 'history', new: 'newRelease', ranking: 'ranking' } as const)[id as 'fantasy'] ?? 'category'; }

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
