/**
 * Plugin API v1 adapter for repository UUID `douyinxiaoshuo-biquge`.
 *
 * The adapter owns activation, opaque pagination cursors and bounded stage logs. Site HTTP,
 * parsing and stable content identities remain in source.ts.
 */
import {
  categories,
  type Context,
  DouyinXiaoshuoSource,
} from './source.js';

interface ActiveContext extends Context {
  readonly dataDir: string;
  readonly app: object;
  readonly plugin: object;
}

interface PageRequest {
  readonly cursor: string | null;
  readonly pageSize: number;
}

let context: ActiveContext | undefined;
let source: DouyinXiaoshuoSource | undefined;

export async function activate(nextContext: ActiveContext): Promise<void> {
  context = nextContext;
  nextContext.log.info('source_activated');
}

export async function search(
  request: PageRequest & { readonly query: string },
) {
  return invoke('search', async () => {
    const offset = decodeSearchCursor(request.cursor);
    const allItems = await requireSource().search(request.query);
    const items = allItems.slice(offset, offset + request.pageSize);
    const nextOffset = offset + items.length;
    return Object.freeze({
      items: Object.freeze(items),
      nextCursor: nextOffset < allItems.length ? `search:${nextOffset}` : null,
      totalCount: null,
    });
  });
}

export async function discover(
  request: PageRequest & {
    readonly target: string | null;
    readonly collectionId: string | null;
  },
) {
  return invoke('discover', async () => {
    if (request.target === null) return categoriesDocument();

    const target = /^category:([a-z-]+)$/u.exec(request.target)?.[1];
    if (target === undefined || !categories.some(([id]) => id === target)) {
      throw new Error('Discovery target is invalid.');
    }
    const collectionId = `category-books:${target}`;
    if (
      request.collectionId !== null &&
      request.collectionId !== collectionId
    ) {
      throw new Error('Discovery collection is invalid.');
    }

    const { page, offset } = decodeDiscoveryCursor(request.cursor, target);
    const listing = await requireSource().discover(target, page);
    const contents = listing.items.slice(offset, offset + request.pageSize);
    const items = Object.freeze(
      contents.map((content) =>
        Object.freeze({
          content,
          rank: null,
          metric: null,
          recommendation: null,
        }),
      ),
    );
    const nextOffset = offset + contents.length;
    const continuation =
      nextOffset < listing.items.length
        ? Object.freeze({
            target: request.target,
            cursor: `category:${target}:${page}:${nextOffset}`,
          })
        : listing.hasNext
          ? Object.freeze({
              target: request.target,
              cursor: `category:${target}:${page + 1}:0`,
            })
          : null;

    if (request.collectionId !== null) {
      return Object.freeze({
        kind: 'append' as const,
        collectionId,
        items,
        continuation,
      });
    }

    const title =
      categories.find(([id]) => id === target)?.[1] ?? '分类';
    return Object.freeze({
      kind: 'document' as const,
      document: {
        components: Object.freeze([
          {
            type: 'section' as const,
            id: `${collectionId}-section`,
            title,
            subtitle: null,
            children: Object.freeze([
              {
                type: 'contentCollection' as const,
                id: collectionId,
                layout: 'list' as const,
                items,
                continuation,
              },
            ]),
          },
        ]),
      },
    });
  });
}

export async function searchSuggestions() {
  return Object.freeze({ items: Object.freeze([]), nextCursor: null });
}

export async function getDetail(request: { readonly id: string }) {
  return invoke('detail', () => requireSource().getDetail(request.id));
}

export async function getChapters(request: { readonly id: string }) {
  return invoke('chapters', () => requireSource().getChapters(request.id));
}

export async function getContent(request: {
  readonly id: string;
  readonly chapterId: string;
}) {
  return invoke('content', () =>
    requireSource().getContent(request.id, request.chapterId),
  );
}

export async function resource(request: Record<string, unknown>) {
  return requireSource().resource(request);
}

function requireSource(): DouyinXiaoshuoSource {
  if (context === undefined) throw new Error('Source is not activated.');
  return (source ??= new DouyinXiaoshuoSource(context));
}

function categoriesDocument() {
  return Object.freeze({
    kind: 'document' as const,
    document: {
      components: Object.freeze([
        {
          type: 'section' as const,
          id: 'categories-section',
          title: '分类',
          subtitle: null,
          children: Object.freeze([
            {
              type: 'categoryCollection' as const,
              id: 'categories',
              layout: 'grid' as const,
              categories: Object.freeze(
                categories.map(([id, title]) =>
                  Object.freeze({
                    id,
                    title,
                    target: `category:${id}`,
                    count: null,
                    url: null,
                  }),
                ),
              ),
            },
          ]),
        },
      ]),
    },
  });
}

async function invoke<T>(
  stage: string,
  action: () => Promise<T>,
): Promise<T> {
  if (context === undefined) throw new Error('Source is not activated.');
  context.log.info(`source_${stage}_started`);
  try {
    const result = await action();
    context.log.info(`source_${stage}_completed`);
    return result;
  } catch (error) {
    const code = error instanceof Error ? error.name : typeof error;
    context.log.warn(`source_${stage}_failed error_code=${code}`);
    throw error;
  }
}

function decodeSearchCursor(value: string | null): number {
  if (value === null) return 0;
  const offset = Number(/^search:(\d+)$/u.exec(value)?.[1]);
  if (!Number.isSafeInteger(offset) || offset < 1) {
    throw new Error('Search cursor is invalid.');
  }
  return offset;
}

function decodeDiscoveryCursor(
  value: string | null,
  categoryId: string,
): { readonly page: number; readonly offset: number } {
  if (value === null) return Object.freeze({ page: 1, offset: 0 });
  const match = /^category:([a-z-]+):(\d+):(\d+)$/u.exec(value);
  const page = Number(match?.[2]);
  const offset = Number(match?.[3]);
  if (
    match?.[1] !== categoryId ||
    !Number.isSafeInteger(page) ||
    page < 1 ||
    !Number.isSafeInteger(offset) ||
    offset < 0
  ) {
    throw new Error('Discovery cursor is invalid.');
  }
  return Object.freeze({ page, offset });
}
