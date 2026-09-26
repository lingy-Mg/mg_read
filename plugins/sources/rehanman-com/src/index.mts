/** Plugin API adapter for Rehanman public webtoon pages. */
import { position, window as pageWindow, type DiscoveryResult } from './discovery-page.js';

import { RehanmanSource, type Context } from './source.js';

type RequestContext = Context;
interface PageRequest { readonly cursor: string | null; readonly pageSize: number; }
let source: RehanmanSource | undefined;

export async function activate(context: RequestContext) {
  source = new RehanmanSource(context);
  context.log.info('source_activated');
}

export async function discover(request: PageRequest & {readonly target:string|null;readonly collectionId:string|null}): Promise<DiscoveryResult> {
  const size = Math.max(1, Math.min(50, request.pageSize));
  if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null) throw new Error('Initial discovery request is invalid.');
    const latest = await discover({target:'latest',cursor:null,collectionId:null,pageSize:Math.min(5,size)});
    const rails = await requireSource().home();
    return {kind:'document',document:{components:[...(latest.kind==='document'?latest.document.components:[]),...rails.map(rail=>railSection(rail.id,rail.title,rail.items,0,Math.min(5,size)))]}};
  }
  if (request.target.startsWith('home:')) {
    const id = request.target.slice(5);
    if (!['today','popular','recommended'].includes(id)) throw new Error('Target is invalid.');
    const {page,offset} = position(request.cursor,request.target);
    if (page !== 1 || (request.collectionId !== null && request.collectionId !== request.target)) throw new Error('Discovery cursor or collection is invalid.');
    const rail = (await requireSource().home()).find(value=>value.id===id);
    if (!rail) throw new Error('Homepage section is unavailable.');
    const section = railSection(id,rail.title,rail.items,offset,size);
    const collection = section.children[0]!;
    return request.collectionId === null ? {kind:'document',document:{components:[section]}} : {kind:'append',collectionId:request.target,items:collection.items,continuation:collection.continuation};
  }
  if(request.target!=='latest')throw new Error('Target is invalid.');
  if(request.collectionId!==null&&request.collectionId!=='latest')throw new Error('Discovery collection is invalid.');
  const {page,offset}=position(request.cursor,'latest'),result=await requireSource().latest(page);
  const {values,continuation}=pageWindow(result.items,'latest',page,offset,size,result.hasNext);
  const items=values.map(content=>({content,rank:null,metric:null,recommendation:null}));
  if(request.collectionId!==null)return {kind:'append',collectionId:'latest',items,continuation};
  return {kind:'document',document:{components:[{type:'section',id:'latest-section',title:'新漫画',subtitle:null,icon:'newRelease',children:[{type:'contentCollection',id:'latest',layout:'coverGrid',items,continuation}]}]}};
}
function railSection(id:string,title:string,all:readonly object[],offset:number,size:number) {
  const target='home:'+id, {values,continuation}=pageWindow(all,target,1,offset,size,false);
  return {type:'section',id:target+'-section',title,subtitle:null,children:[{type:'contentCollection',id:target,layout:'coverGrid',items:values.map(content=>({content,rank:null,metric:null,recommendation:null})),continuation}]};
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
