/** Plugin API adapter and source-owned discovery composition for 66manhua.cc. */
import { ManhuaSource, type Context, type RankedSummary, type Summary } from './source.js';

type RequestContext = Context;
interface PageRequest { readonly cursor: string | null; readonly pageSize: number; }
let context: RequestContext | undefined; let source: ManhuaSource | undefined;

// Discovery cover URLs are Runtime-owned, self-contained proxy URLs. Keep all
// homepage sections while leaving enough room under the public inline-result
// budget for those URLs and normal upstream title/description variation.
const discoveryItemLimits = Object.freeze({
  completed: 8,
  featured: 6,
  popular: 8,
  ranking: 4,
  recent: 8,
  rising: 8,
});

export async function activate(next: RequestContext) { context = next; source = undefined; next.log.info('source_activated'); }
export async function search(request: PageRequest & { readonly query: string }) { rejectCursor(request.cursor); const items = (await requireSource().search(request.query)).slice(0, request.pageSize); return Object.freeze({ items, nextCursor: null, totalCount: null }); }
export async function discover(request: PageRequest & { readonly target: string | null; readonly collectionId: string | null }) {
  if(request.target!==null) {
    const match=/^section:([a-z0-9-]+)$/u.exec(request.target);if(!match)throw new Error('Discovery target is invalid.');
    const home=await requireSource().discover(), id=match[1]!, group=home.rankings.find(value=>value.id===id);
    const plain=id==='featured'?home.featured:id==='recent'?home.recent:id==='completed'?home.completed:null;
    const ranked=id==='rising'?home.rising:id==='popular'?home.popular:group?.items;
    if(!plain&&!ranked)throw new Error('Discovery target is invalid.');
    const all=plain?plain.map(content=>({content,rank:null,metric:null,recommendation:null})):ranked!.map(value=>({...value,recommendation:null}));
    const prefix=request.target+':',raw=request.cursor?.startsWith(prefix)?request.cursor.slice(prefix.length):'';
    const offset=request.cursor===null?0:/^\d+$/u.test(raw)?Number(raw):NaN;
    if(!Number.isSafeInteger(offset)||offset<0||offset>10000)throw new Error('Discovery cursor is invalid.');
    const collectionId=id+'-items';if(request.collectionId!==null&&request.collectionId!==collectionId)throw new Error('Discovery collection is invalid.');
    const items=all.slice(offset,offset+Math.max(1,Math.min(50,request.pageSize))),next=offset+items.length;
    const continuation=next<all.length?{target:request.target,cursor:prefix+next}:null;
    if(request.collectionId!==null)return {kind:'append',collectionId,items,continuation};
    const title=group?.title??({featured:'精选推荐',recent:'最近更新',completed:'完结大作',rising:'上升最快',popular:'人气排行榜'} as Record<string,string>)[id]!;
    return {kind:'document',document:{components:[section(id,title,null,ranked?'ranking':'manga',ranked?'compact':'coverGrid',items,continuation)]}};
  }
  if(request.collectionId!==null||request.cursor!==null)throw new Error('Initial discovery request is invalid.');
  const home = await requireSource().discover(); const components: object[] = [];
  addCollection(components, home.featured, request.pageSize, discoveryItemLimits.featured, 'featured', '精选推荐', '官网精选内容', 'recommendation', 'carousel');
  addCollection(components, home.recent, request.pageSize, discoveryItemLimits.recent, 'recent', '最近更新', '追踪最新章节', 'newRelease', 'coverGrid');
  const trendSections: object[] = [];
  addRankedCollection(trendSections, home.rising, request.pageSize, discoveryItemLimits.rising, 'rising', '上升最快', '近期热度增长最快', 'trending', 'compact');
  addRankedCollection(trendSections, home.popular, request.pageSize, discoveryItemLimits.popular, 'popular', '人气排行榜', '站内人气作品', 'hot', 'compact');
  if (trendSections.length !== 0) components.push(Object.freeze({ type: 'group', id: 'trend-group', layout: 'vertical', children: Object.freeze(trendSections) }));
  addCollection(components, home.completed, request.pageSize, discoveryItemLimits.completed, 'completed', '完结大作', '一次读到结局', 'completed', 'shelf');
  const rankingSections: object[] = [];
  for (const ranking of home.rankings) addRankedCollection(rankingSections, ranking.items, request.pageSize, discoveryItemLimits.ranking, ranking.id, ranking.title, null, 'ranking', 'compact');
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
  components.push(section(id, title, subtitle, icon, layout, items, contents.length>items.length?{target:'section:'+id,cursor:'section:'+id+':'+items.length}:null));
}
function addRankedCollection(components: object[], contents: readonly RankedSummary[], pageSize: number, maximumItems: number, id: string, title: string, subtitle: string | null, icon: string, layout: string) {
  if (contents.length === 0) return; const items = contents.slice(0, Math.min(pageSize, maximumItems)).map((item) => Object.freeze({ ...item, recommendation: null }));
  components.push(section(id, title, subtitle, icon, layout, items, contents.length>items.length?{target:'section:'+id,cursor:'section:'+id+':'+items.length}:null));
}
function section(id: string, title: string, subtitle: string | null, icon: string, layout: string, items: readonly object[], continuation: {target:string;cursor:string}|null) { return Object.freeze({ type: 'section', id: `${id}-section`, title, subtitle, icon, children: Object.freeze([{ type: 'contentCollection', id: `${id}-items`, layout, items: Object.freeze(items), continuation }]) }); }
