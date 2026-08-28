/** Plugin API adapter for the 66manhua.cc source. */
import { ManhuaSource, type Context } from './source.js';

interface RequestContext extends Context { readonly dataDir: string; readonly app: object; readonly plugin: object; }
interface PageRequest { readonly cursor: string | null; readonly pageSize: number; }
let context: RequestContext | undefined; let source: ManhuaSource | undefined;

export async function activate(next: RequestContext) { context = next; next.log.info('source_activated'); }
export async function search(request: PageRequest & { readonly query: string }) { rejectCursor(request.cursor); const items = (await requireSource().search(request.query)).slice(0, request.pageSize); return Object.freeze({ items, nextCursor: null, totalCount: null }); }
export async function discover(request: PageRequest & { readonly target: string | null; readonly collectionId: string | null }) { if (request.target !== null || request.collectionId !== null) throw new Error('Discovery target is invalid.'); rejectCursor(request.cursor); const items = (await requireSource().discover()).slice(0, request.pageSize).map((content) => Object.freeze({ content, rank: null, metric: null, recommendation: null })); return Object.freeze({ kind: 'document', document: { components: Object.freeze([{ type: 'section', id: 'public-home', title: '首页', subtitle: null, icon: 'manga', children: Object.freeze([{ type: 'contentCollection', id: 'public-home-items', layout: 'coverGrid', items: Object.freeze(items), continuation: null }]) }]) } }); }
export async function searchSuggestions() { return Object.freeze({ items: Object.freeze([]), nextCursor: null }); }
export async function getDetail(request: { readonly id: string }) { return requireSource().detail(request.id); }
export async function getChapters(request: { readonly id: string }) { return requireSource().chapters(request.id); }
export async function getContent(request: { readonly id: string; readonly chapterId: string }) { return requireSource().content(request.id, request.chapterId); }
export async function resource(request: Record<string, unknown>) { return requireSource().resource(request); }
function requireSource() { if (context === undefined) throw new Error('Source is not activated.'); return source ??= new ManhuaSource(context); }
function rejectCursor(cursor: string | null) { if (cursor !== null) throw new Error('Cursor is invalid.'); }
