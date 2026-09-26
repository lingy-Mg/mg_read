/** Plugin API v1 adapter for the repository source `baozimh-com`. */
import { position, window as pageWindow, type DiscoveryResult } from './discovery-page.js';

import type { ChaptersRequest, ContentReferenceRequest, ContentRequest, DiscoverRequest, MgReadPluginContext, SearchRequest, SearchSuggestionsRequest } from './contracts.js';
import { categories, BaozimhSource } from './source.js';
import { defaults, filterSections, readFilters } from './discovery-filters.js';

let context: MgReadPluginContext | undefined;
let source: BaozimhSource | undefined;
export async function activate(next: MgReadPluginContext): Promise<void> { context = next; source = undefined; next.log.info('source_activated'); }
export async function search(request: SearchRequest) {
  if (request.cursor !== null) throw new Error('Search cursor is unsupported.');
  return invoke('search', async (active) => Object.freeze({ items: Object.freeze((await active.search(request.query)).slice(0, request.pageSize)), nextCursor: null, totalCount: null }));
}
export async function discover(request: DiscoverRequest) {
  if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null) throw new Error('Initial discovery request is invalid.');
    const resultPage = await invoke('discover_home', (active) => active.browsePage({...defaults,region:'cn'},null));
    const content = resultPage.items;
    const size = Math.min(request.pageSize, 10);
    const result = categoriesDocument(content.slice(0, size), continuationFor('category:china',1,Math.min(size,content.length),content.length,null,resultPage.next));
    return {kind:'document' as const,document:{components:[...result.document.components,...filterSections({...defaults,region:'cn'})]}};
  }
  const categoryId = /^category:([a-z-]+)$/u.exec(request.target)?.[1];
  const category = categories.find(([id])=>id===categoryId);
  const filters = request.target.startsWith('filter:') ? readFilters(request.target) : category ? Object.fromEntries(new URL(category[2],'https://www.baozimh.com').searchParams) as typeof defaults : null;
  if (!filters) throw new Error('Discovery target is invalid.');
  const collectionId = category ? 'category-books:' + categoryId : request.target;
  if(request.collectionId!==null&&request.collectionId!==collectionId)throw new Error('Discovery collection is invalid.');
  const parts=request.cursor?.split('~')??[],{page,offset}=position(parts[0]??null,request.target);
  if(parts.length>2||(page===1&&parts.length>1)||(page>1&&(!parts[1]||!/^[A-Za-z0-9_-]{1,1400}$/u.test(parts[1]))))throw new Error('Discovery cursor is invalid.');
  const path=parts[1]?Buffer.from(parts[1],'base64url').toString():null;
  const resultPage=await invoke('discover',active=>active.browsePage(filters,path)),content=resultPage.items;
  const values=content.slice(offset,offset+Math.max(1,Math.min(50,request.pageSize)));
  const continuation=continuationFor(request.target,page,offset+values.length,content.length,path,resultPage.next);
  const items=values.map(content=>({content,rank:null,metric:null,recommendation:null}));
  if(request.collectionId!==null)return {kind:'append' as const,collectionId,items,continuation};
  return {kind:'document' as const,document:{components:[{type:'section',id:collectionId+'-section',title:categories.find(([id])=>id===categoryId)?.[1]??'分类',subtitle:null,children:[{type:'contentCollection',id:collectionId,layout:'coverGrid',items,continuation}]},...filterSections(filters)]}};
}

function continuationFor(target:string,page:number,offset:number,total:number,path:string|null,next:string|null) {
  if(offset>=total&&(!next||page>=10000))return null;
  const nextPath=offset<total?path:next;
  return {target,cursor:target+':'+(offset<total?page:page+1)+':'+(offset<total?offset:0)+(nextPath?'~'+Buffer.from(nextPath).toString('base64url'):'')};
}

export async function searchSuggestions(_request: SearchSuggestionsRequest) { return Object.freeze({ items: Object.freeze([]), nextCursor: null }); }
export async function getDetail(request: ContentReferenceRequest) { return invoke('get_detail', (active) => active.getDetail(request.id)); }
export async function getChapters(request: ChaptersRequest) { return invoke('get_chapters', (active) => active.getChapters(request.id)); }
export async function getContent(request: ContentRequest) { return invoke('get_content', (active) => active.getContent(request.id, request.chapterId)); }
function categoriesDocument(content: readonly Awaited<ReturnType<BaozimhSource['discover']>>[number][], continuation: {target:string;cursor:string}|null) { const items = Object.freeze(content.map((value) => Object.freeze({ content: value, rank: null, metric: null, recommendation: null }))); return Object.freeze({ kind: 'document' as const, document: { components: Object.freeze([...(items.length === 0 ? [] : [{ type: 'section' as const, id: 'featured-section', title: '国漫推荐', subtitle: '国漫频道新近作品', icon: 'manga' as const, children: Object.freeze([{ type: 'contentCollection' as const, id: 'category-books:china', layout: 'coverGrid' as const, items, continuation }]) }]), { type: 'section' as const, id: 'categories-section', title: '漫画分类', subtitle: '按地区或题材继续发现', icon: 'explore' as const, children: Object.freeze([{ type: 'categoryCollection' as const, id: 'categories', layout: 'chips' as const, categories: Object.freeze(categories.map(([id, title]) => Object.freeze({ id, title, target: `category:${id}`, count: null, url: null, icon: id === 'romance' ? 'romance' : id === 'action' ? 'hot' : id === 'fantasy' ? 'fantasy' : 'manga' }))) }]) }]) } }); }
function requireSource(): BaozimhSource { if (context === undefined) throw new Error('Source is not activated.'); return source ??= new BaozimhSource(context); }
async function invoke<T>(operation: string, action: (active: BaozimhSource) => Promise<T>): Promise<T> { if (context === undefined) throw new Error('Source is not activated.'); context.log.info(`source_${operation}_started`); try { const result = await action(requireSource()); context.log.info(`source_${operation}_completed`); return result; } catch (error) { context.log.warn(`source_${operation}_failed`); throw error; } }
