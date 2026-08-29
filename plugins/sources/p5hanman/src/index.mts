/**
 * Plugin API v1 adapter for repository UUID `p5hanman`.
 *
 * Owns activation, source-safe logs and offset-aware opaque cursors. HTML parsing and media
 * proxy decisions remain in source.ts.
 */
import { categories, type Context, P5HanmanSource } from './source.js';

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
let source: P5HanmanSource | undefined;

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
    const categoryId = /^category:([a-z-]+)$/u.exec(request.target)?.[1];
    if (
      categoryId === undefined ||
      !categories.some(([id]) => id === categoryId)
    ) {
      throw new Error('Discovery target is invalid.');
    }
    const collectionId = `category-manga:${categoryId}`;
    if (
      request.collectionId !== null &&
      request.collectionId !== collectionId
    ) {
      throw new Error('Discovery collection is invalid.');
    }

    const { page, offset } = decodeDiscoveryCursor(
      request.cursor,
      categoryId,
    );
    const listing = await requireSource().discover(categoryId, page);
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
            cursor: `category:${categoryId}:${page}:${nextOffset}`,
          })
        : listing.hasNext
          ? Object.freeze({
              target: request.target,
              cursor: `category:${categoryId}:${page + 1}:0`,
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
      categories.find(([id]) => id === categoryId)?.[1] ?? '漫画';
    return Object.freeze({
      kind: 'document' as const,
      document: {
        components: Object.freeze([
          Object.freeze({
            type: 'section' as const,
            id: `${collectionId}-section`,
            title,
            subtitle: null,
            children: Object.freeze([
              Object.freeze({
                type: 'contentCollection' as const,
                id: collectionId,
                layout: 'coverGrid' as const,
                items,
                continuation,
              }),
            ]),
          }),
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

function requireSource(): P5HanmanSource {
  if (context === undefined) throw new Error('Source is not activated.');
  return (source ??= new P5HanmanSource(context));
}

function categoriesDocument() {
  return Object.freeze({
    kind: 'document' as const,
    document: {
      components: Object.freeze([
        Object.freeze({
          type: 'section' as const,
          id: 'categories-section',
          title: '漫画分类',
          subtitle: null,
          children: Object.freeze([
            Object.freeze({
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
            }),
          ]),
        }),
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
