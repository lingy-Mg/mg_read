/**
 * Plugin API v1 adapter for repository UUID `dandanyuedu`.
 *
 * Owns activation, opaque cursors and bounded stage logs. QQ API fields, IDs and anonymous
 * content-client state remain in source.ts.
 */
import { categories, DandanYueduSource, } from './source.js';
let context;
let source;
export async function activate(nextContext) {
    context = nextContext;
    source = new DandanYueduSource(nextContext);
    nextContext.log.info('source_activated');
}
export async function search(request) {
    return invoke('search', async () => {
        const start = decodeSearchCursor(request.cursor);
        const result = await requireSource().search(request.query, start, Math.min(request.pageSize, 30));
        return Object.freeze({
            items: result.items,
            nextCursor: result.nextStart === null ? null : `search:${result.nextStart}`,
            totalCount: null,
        });
    });
}
export async function discover(request) {
    return invoke('discover', async () => {
        if (request.target === null) {
            if (request.cursor !== null || request.collectionId !== null) {
                throw new Error('Initial discovery request is invalid.');
            }
            const listing = await requireSource().discover('ancient-romance', 1);
            return categoriesDocument(listing.items.slice(0, Math.min(request.pageSize, 10)));
        }
        const categoryId = /^category:([a-z-]+)$/u.exec(request.target)?.[1];
        if (categoryId === undefined ||
            !categories.some(([id]) => id === categoryId)) {
            throw new Error('Discovery target is invalid.');
        }
        const collectionId = `category-books:${categoryId}`;
        if (request.collectionId !== null &&
            request.collectionId !== collectionId) {
            throw new Error('Discovery collection is invalid.');
        }
        const { page, offset } = decodeDiscoveryCursor(request.cursor, categoryId);
        const listing = await requireSource().discover(categoryId, page);
        const contents = listing.items.slice(offset, offset + request.pageSize);
        const items = Object.freeze(contents.map((content) => Object.freeze({
            content,
            rank: null,
            metric: null,
            recommendation: null,
        })));
        const nextOffset = offset + contents.length;
        const continuation = nextOffset < listing.items.length
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
                kind: 'append',
                collectionId,
                items,
                continuation,
            });
        }
        const title = categories.find(([id]) => id === categoryId)?.[1] ?? '分类';
        return Object.freeze({
            kind: 'document',
            document: {
                components: Object.freeze([
                    Object.freeze({
                        type: 'section',
                        id: `${collectionId}-section`,
                        title,
                        subtitle: null,
                        children: Object.freeze([
                            Object.freeze({
                                type: 'contentCollection',
                                id: collectionId,
                                layout: 'list',
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
export async function getDetail(request) {
    return invoke('detail', () => requireSource().getDetail(request.id));
}
export async function getChapters(request) {
    return invoke('chapters', () => requireSource().getChapters(request.id));
}
export async function getContent(request) {
    return invoke('content', () => requireSource().getContent(request.id, request.chapterId));
}
function requireSource() {
    if (context === undefined || source === undefined) {
        throw new Error('Source is not activated.');
    }
    return source;
}
function categoriesDocument(content) {
    const items = Object.freeze(content.map((value) => Object.freeze({
        content: value,
        rank: null,
        metric: null,
        recommendation: null,
    })));
    return Object.freeze({
        kind: 'document',
        document: {
            components: Object.freeze([
                ...(items.length === 0
                    ? []
                    : [
                        Object.freeze({
                            type: 'section',
                            id: 'featured-section',
                            title: '古言新作',
                            subtitle: '女频原创内容精选',
                            icon: 'newRelease',
                            children: Object.freeze([
                                Object.freeze({
                                    type: 'contentCollection',
                                    id: 'featured-books',
                                    layout: 'shelf',
                                    items,
                                    continuation: null,
                                }),
                            ]),
                        }),
                    ]),
                Object.freeze({
                    type: 'section',
                    id: 'categories-section',
                    title: '小说分类',
                    subtitle: '按题材继续发现',
                    icon: 'explore',
                    children: Object.freeze([
                        Object.freeze({
                            type: 'categoryCollection',
                            id: 'categories',
                            layout: 'chips',
                            categories: Object.freeze(categories.map(([id, title]) => Object.freeze({
                                id,
                                title,
                                target: `category:${id}`,
                                count: null,
                                url: null,
                                icon: categoryIcon(id),
                            }))),
                        }),
                    ]),
                }),
            ]),
        },
    });
}
function categoryIcon(id) {
    return {
        'ancient-romance': 'romance',
        'modern-romance': 'romance',
        'fantasy-romance': 'fantasy',
        cultivation: 'wuxia',
        youth: 'school',
        game: 'game',
        'science-fiction': 'scienceFiction',
        mystery: 'mystery',
        'light-novel': 'lightNovel',
    }[id] ?? 'book';
}
async function invoke(stage, action) {
    if (context === undefined)
        throw new Error('Source is not activated.');
    context.log.info(`source_${stage}_started`);
    try {
        const result = await action();
        context.log.info(`source_${stage}_completed`);
        return result;
    }
    catch (error) {
        const code = error instanceof Error ? error.name : typeof error;
        context.log.warn(`source_${stage}_failed error_code=${code}`);
        throw error;
    }
}
function decodeSearchCursor(value) {
    if (value === null)
        return 0;
    const start = Number(/^search:(\d+)$/u.exec(value)?.[1]);
    if (!Number.isSafeInteger(start) || start < 1) {
        throw new Error('Search cursor is invalid.');
    }
    return start;
}
function decodeDiscoveryCursor(value, categoryId) {
    if (value === null)
        return Object.freeze({ page: 1, offset: 0 });
    const match = /^category:([a-z-]+):(\d+):(\d+)$/u.exec(value);
    const page = Number(match?.[2]);
    const offset = Number(match?.[3]);
    if (match?.[1] !== categoryId ||
        !Number.isSafeInteger(page) ||
        page < 1 ||
        !Number.isSafeInteger(offset) ||
        offset < 0) {
        throw new Error('Discovery cursor is invalid.');
    }
    return Object.freeze({ page, offset });
}
