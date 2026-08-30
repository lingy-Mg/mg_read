/** Plugin API adapter and source-owned discovery composition for 66manhua.cc. */
import { ManhuaSource, type Context, type RankedSummary, type Summary } from './source.js';

interface RequestContext extends Context { readonly dataDir: string; readonly app: object; readonly plugin: object; }
interface PageRequest { readonly cursor: string | null; readonly pageSize: number; }
let context: RequestContext | undefined; let source: ManhuaSource | undefined;

export async function activate(next: RequestContext) { context = next; next.log.info('source_activated'); }
export async function search(request: PageRequest & { readonly query: string }) { rejectCursor(request.cursor); const items = (await requireSource().search(request.query)).slice(0, request.pageSize); return Object.freeze({ items, nextCursor: null, totalCount: null }); }
export async function discover(request: PageRequest & { readonly target: string | null; readonly collectionId: string | null }) {
  if (request.target !== null || request.collectionId !== null) throw new Error('Discovery target is invalid.'); rejectCursor(request.cursor);
  const home = await requireSource().discover(); const components: object[] = [];
  addCollection(components, home.featured, request.pageSize, 8, 'featured', '精选推荐', '官网精选内容', 'recommendation', 'carousel');
  addCollection(components, home.recent, request.pageSize, 12, 'recent', '最近更新', '追踪最新章节', 'newRelease', 'coverGrid');
  const trendSections: object[] = [];
  addRankedCollection(trendSections, home.rising, request.pageSize, 10, 'rising', '上升最快', '近期热度增长最快', 'trending', 'compact');
  addRankedCollection(trendSections, home.popular, request.pageSize, 10, 'popular', '人气排行榜', '站内人气作品', 'hot', 'compact');
  if (trendSections.length !== 0) components.push(Object.freeze({ type: 'group', id: 'trend-group', layout: 'vertical', children: Object.freeze(trendSections) }));
  addCollection(components, home.completed, request.pageSize, 10, 'completed', '完结大作', '一次读到结局', 'completed', 'shelf');
  const rankingSections: object[] = [];
  for (const ranking of home.rankings) addRankedCollection(rankingSections, ranking.items, request.pageSize, 6, ranking.id, ranking.title, null, 'ranking', 'compact');
  if (rankingSections.length !== 0) components.push(Object.freeze({ type: 'group', id: 'ranking-group', layout: 'vertical', children: Object.freeze(rankingSections) }));
  return Object.freeze({ kind: 'document', document: Object.freeze({ components: Object.freeze(components) }) });
}
export async function searchSuggestions() { return Object.freeze({ items: Object.freeze([]), nextCursor: null }); }
export async function getDetail(request: { readonly id: string }) { return requireSource().detail(request.id); }
export async function getChapters(request: { readonly id: string }) { return requireSource().chapters(request.id); }
export async function getContent(request: { readonly id: string; readonly chapterId: string }) { return requireSource().content(request.id, request.chapterId); }
function requireSource() { if (context === undefined) throw new Error('Source is not activated.'); return source ??= new ManhuaSource(context); }
function rejectCursor(cursor: string | null) { if (cursor !== null) throw new Error('Cursor is invalid.'); }
function addCollection(components: object[], contents: readonly Summary[], pageSize: number, maximumItems: number, id: string, title: string, subtitle: string | null, icon: string, layout: string) {
  if (contents.length === 0) return; const items = contents.slice(0, Math.min(pageSize, maximumItems)).map((content) => Object.freeze({ content, rank: null, metric: null, recommendation: null }));
  components.push(section(id, title, subtitle, icon, layout, items));
}
function addRankedCollection(components: object[], contents: readonly RankedSummary[], pageSize: number, maximumItems: number, id: string, title: string, subtitle: string | null, icon: string, layout: string) {
  if (contents.length === 0) return; const items = contents.slice(0, Math.min(pageSize, maximumItems)).map((item) => Object.freeze({ ...item, recommendation: null }));
  components.push(section(id, title, subtitle, icon, layout, items));
}
function section(id: string, title: string, subtitle: string | null, icon: string, layout: string, items: readonly object[]) { return Object.freeze({ type: 'section', id: `${id}-section`, title, subtitle, icon, children: Object.freeze([{ type: 'contentCollection', id: `${id}-items`, layout, items: Object.freeze(items), continuation: null }]) }); }
