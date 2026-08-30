/** Plugin API adapter for Rehanman public webtoon pages. */
import { RehanmanSource, type Context } from './source.js';

interface RequestContext extends Context { readonly dataDir: string; readonly app: object; readonly plugin: object; }
interface PageRequest { readonly cursor: string | null; readonly pageSize: number; }
let source: RehanmanSource | undefined;

export async function activate(context: RequestContext) {
  source = new RehanmanSource(context);
  context.log.info('source_activated');
}

export async function discover(request: PageRequest & { readonly target: string | null; readonly collectionId: string | null }) {
  if (request.target !== null && request.target !== 'latest') throw new Error('Target is invalid.');
  const page = parseCursor(request.cursor);
  const result = await requireSource().latest(page);
  const items = result.items.slice(0, request.pageSize)
    .map((content) => Object.freeze({ content, rank: null, metric: null, recommendation: null }));
  const continuation = result.hasNext && items.length === request.pageSize ? Object.freeze({ target: 'latest', cursor: `latest:${page + 1}` }) : null;
  if (request.collectionId !== null) return Object.freeze({ kind: 'append', collectionId: 'latest', items: Object.freeze(items), continuation });
  return Object.freeze({ kind: 'document', document: { components: Object.freeze([
    Object.freeze({ type: 'section', id: 'latest-section', title: '最新漫画', subtitle: null, children: Object.freeze([
      Object.freeze({ type: 'contentCollection', id: 'latest', layout: 'coverGrid', items: Object.freeze(items), continuation }),
    ]) }),
  ]) } });
}

export async function search(request: PageRequest & { readonly query: string }) {
  const page = parseCursor(request.cursor, 'search'); const query = request.query.trim();
  if (query === '') return Object.freeze({ items: Object.freeze([]), nextCursor: null, totalCount: 0 });
  const result = await requireSource().search(query, page); const items = result.items.slice(0, request.pageSize);
  return Object.freeze({ items: Object.freeze(items), nextCursor: result.hasNext && items.length === request.pageSize ? `search:${page + 1}` : null, totalCount: result.totalCount });
}

export async function searchSuggestions() { return Object.freeze({ items: Object.freeze([]), nextCursor: null }); }
export async function getDetail(request: { readonly id: string }) { return requireSource().detail(request.id); }
export async function getChapters(request: { readonly id: string }) { return requireSource().chapters(request.id); }
export async function getContent(request: { readonly id: string; readonly chapterId: string }) { return requireSource().content(request.id, request.chapterId); }

function requireSource() { if (source === undefined) throw new Error('Source is not activated.'); return source; }
function parseCursor(value: string | null, scope = 'latest') { if (value === null) return 1; const match = new RegExp(`^${scope}:(\\d+)$`, 'u').exec(value); const page = Number(match?.[1]); if (!Number.isSafeInteger(page) || page < 2) throw new Error('Cursor is invalid.'); return page; }
