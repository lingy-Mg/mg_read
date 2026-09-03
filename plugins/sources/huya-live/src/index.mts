/**
 * 虎牙直播原生数据源。
 *
 * 职责：直接调用虎牙房间列表，并解析直播线路服务返回的 AES-ECB 数据。
 * 生命周期：activate 注入 Runtime；不保存登录态或系统凭据。
 * IO：列表和线路请求走 ctx.http；封面、FLV/HLS 媒体经 ctx.resource.proxy。
 * 稳定标识：房间使用虎牙 profile room ID，线路使用上游地址摘要。
 */
import { createDecipheriv, createHash } from 'node:crypto';
import type { MgReadPluginContext } from '@mgread/source-api';

type Json = Record<string, unknown>;
type Context = MgReadPluginContext;
const listApi = 'https://live.huya.com/liveHttpUI/getLiveList';
const detailApi = 'http://dh.baicanuc.cn:3000/getHuyaData';
const web = 'https://www.huya.com/';
const userAgent = 'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 Chrome/72.0.3626.81 Safari/537.36';
const headers = Object.freeze({ Accept: 'application/json,text/plain,*/*', Referer: web, 'User-Agent': userAgent });
const categories = Object.freeze([
  ['1','英雄联盟'],['862','CS2'],['5937','无畏契约'],['5485','云顶之弈'],['4','穿越火线'],['393','炉石传说'],
  ['2793','天天吃鸡'],['100032','主机游戏'],['6219','永劫无间'],['5011','Apex英雄'],
  ['2165','户外'],['1663','星秀'],['2356','体育'],['2135','一起看'],['2633','二次元'],['3793','音乐'],
  ['2336','王者荣耀'],['3203','和平精英'],['7185','金铲铲之战'],['6203','英雄联盟手游']
] as const);
let context: Context | undefined;

export async function activate(next: Context): Promise<void> { context = next; next.log.info('source_activated'); }
export async function search(_request:{query:string;cursor:string|null;pageSize:number}) { return frozen({ items: [], nextCursor: null, totalCount: 0 }); }
export async function searchSuggestions(_request:{cursor:string|null;pageSize:number}) { return frozen({ items: [], nextCursor: null }); }

export async function discover(request:{target:string|null;cursor:string|null;collectionId:string|null;pageSize:number}) {
  if(request.target===null){if(request.cursor!==null||request.collectionId!==null)throw new Error('Initial discovery request is invalid.');return frozen({kind:'document' as const,document:{components:[{type:'section',id:'huya-categories',title:'虎牙直播',subtitle:'按游戏与频道浏览',icon:'video',children:[{type:'categoryCollection',id:'huya-category-list',layout:'chips',categories:categories.map(([id,title])=>({id,title,target:`category:${id}`,count:null,url:null,icon:'video'}))}]}]}});}
  const category=categories.find(([id])=>request.target===`category:${id}`);if(category===undefined)throw new Error('Discovery target is invalid.');
  const page=cursorPage(request.cursor,request.target),limit=clamp(request.pageSize),[id,title]=category;
  const response=await requireContext().http.fetch(`${listApi}?iGid=${encodeURIComponent(id)}&iPageNo=${page}&iPageSize=${Math.max(limit,30)}`,{headers});if(!response.ok)throw new Error('Source request failed.');
  const json:unknown=await response.json();if(!isObject(json))throw new Error('Source response is invalid.');const values=pickList(json).map(roomSummary).filter(notNull).slice(0,limit),collectionId=`huya:${id}`;
  const items=values.map(content=>frozen({content,rank:null,metric:null,recommendation:null})),continuation=values.length>=limit?frozen({target:request.target,cursor:`${request.target}:${page+1}`}):null;
  if(request.collectionId!==null){if(request.collectionId!==collectionId)throw new Error('Discovery collection is invalid.');return frozen({kind:'append' as const,collectionId,items,continuation});}
  return frozen({kind:'document' as const,document:{components:[{type:'section',id:`${collectionId}:section`,title,subtitle:null,icon:'video',children:[{type:'contentCollection',id:collectionId,layout:'coverGrid',items,continuation}]}]}});
}

export async function getDetail(request:{id:string}) { const roomId=contentId(request.id),data=await loadDetail(roomId),info=roomInfo(data,roomId),item=summary(roomId,info.title,info.author,info.cover,info.category);return frozen({...item,description:`房间号：${roomId}${info.author?`\n主播：${info.author}`:''}\n不要相信视频中的任何广告。`,aliases:[],catalogUrl:`${web}${encodeURIComponent(roomId)}`}); }
export async function getChapters(request:{id:string}) { const roomId=contentId(request.id),data=await loadDetail(roomId),streams=collectStreams(data),items=streams.map((stream,index)=>chapter(roomId,stream,index));return frozen({items,groups:items.length===0?[]:[frozen({id:`group:${encodeKey(roomId)}:live`,title:'直播线路',order:0,episodes:items})]}); }
export async function getContent(request:{id:string;chapterId:string}) { const roomId=contentId(request.id),key=chapterKey(request.chapterId,roomId),streams=collectStreams(await loadDetail(roomId)),stream=streams.find((value,index)=>streamKey(value,index)===key);if(stream===undefined)throw new Error('Chapter ID is invalid.');const upstream=streamUrl(stream);if(!safeUrl(upstream))throw new Error('Playback address is unavailable.');const resourceType=/\.m3u8(?:$|[?#])/iu.test(upstream)?'hls':'video',mediaHeaders={Referer:web,'User-Agent':userAgent};return frozen({chapterId:request.chapterId,contentKind:'video',title:nullable(first(stream.displayName,stream.name,stream.cdnName,stream.title)),updatedAt:null,text:null,pages:[],media:{url:requireContext().resource.proxy({kind:resourceType,url:upstream,headers:mediaHeaders}),resourceType,resourcePolicy:'sessionOnly',expiresAt:null,mimeType:resourceType==='hls'?'application/vnd.apple.mpegurl':'video/x-flv',headers:mediaHeaders}}); }

async function loadDetail(roomId:string):Promise<Json>{const response=await requireContext().http.fetch(`${detailApi}?rid=${encodeURIComponent(roomId)}`,{headers});if(!response.ok)throw new Error('Source request failed.');const raw=await response.text();const value=parsePayload(raw);if(!isObject(value))throw new Error('Live detail response is invalid.');return value;}
function parsePayload(raw:string):unknown{const trimmed=raw.trim();if(trimmed==='')return{};let value:unknown;try{value=JSON.parse(trimmed);}catch{value=trimmed;}if(isObject(value)&&typeof value.data==='string')value=value.data;if(typeof value!=='string')return value;if(/^https?:\/\//iu.test(value))return{url:value};try{const decipher=createDecipheriv('aes-128-ecb',Buffer.from('0123456789abcdef','utf8'),null);decipher.setAutoPadding(true);const plain=Buffer.concat([decipher.update(Buffer.from(value,'base64')),decipher.final()]).toString('utf8');return JSON.parse(plain);}catch{return{};}}
function roomInfo(data:Json,roomId:string){const info=object(first(data.roomInfo,data.profileInfo,data.liveData,data.room));return{title:text(first(info.vod_name,info.roomName,info.sIntroduction,info.introduction,info.title))||`虎牙房间 ${roomId}`,author:text(first(info.vod_actor,info.sNick,info.nick,info.nickName,info.profileNick)),cover:text(first(info.vod_pic,info.sScreenshot,info.screenshot,info.avatar180,info.avatar)),category:text(first(info.vod_remarks,info.type_name,info.gameName))};}
function collectStreams(data:Json){const groups=records(first(data.data,data.urls,data.lines));const result:Json[]=[];for(const group of groups){const entries=records(first(group.urls,group.urlList,group.lines,group.items));for(const entry of entries.length>0?entries:[group])if(streamUrl(entry)!==''&&!result.some(old=>streamUrl(old)===streamUrl(entry)))result.push(entry);}if(result.length===0&&streamUrl(data)!=='')result.push(data);return result;}
function pickList(root:Json){for(const value of [root.vList,root.data,object(root.data).vList,object(root.data).list,object(root.data).datas,root.list,root.datas]){const list=records(value);if(list.length>0)return list;}return[];}
function roomSummary(item:Json){const id=text(first(item.lProfileRoom,item.profileRoom,item.roomId,item.room_id,item.uid,item.privateHost,item.yyid));if(id==='')return null;return summary(id,text(first(item.sIntroduction,item.introduction,item.roomName,item.title))||`虎牙房间 ${id}`,text(first(item.sNick,item.nick,item.nickName,item.profileNick,item.nickname)),text(first(item.sScreenshot,item.screenshot,item.img,item.sAvatar180,item.avatar180,item.avatar,item.roomPic)),text(first(item.sGameFullName,item.gameFullName,item.gameName,item.gamename)));}
function summary(id:string,title:string,author:string,cover:string,category:string){const key=encodeKey(id);return frozen({id:`live:${key}`,title,contentKind:'video',coverOrientation:'landscape',author:author||null,url:`${web}${encodeURIComponent(id)}`,coverUrl:proxyImage(cover),description:`房间号：${id}${category?`\n分类：${category}`:''}`,language:'zh-CN',status:'ongoing',access:'free',wordCount:null,chapterCount:1,publishedAt:null,updatedAt:null,latestChapter:{id:`live:${key}:main`,title:category||'直播',url:null,updatedAt:null},categories:category?[category]:['直播'],tags:[],attributes:[]});}
function chapter(roomId:string,stream:Json,index:number){return frozen({id:`live:${encodeKey(roomId)}:${streamKey(stream,index)}`,title:text(first(stream.displayName,stream.name,stream.cdnName,stream.title))||`线路${index+1}`,order:index,url:null,volumeTitle:'直播线路',wordCount:null,updatedAt:null,isLocked:null,attributes:[]});}
function streamUrl(value:Json){return text(first(value.url,value.playUrl,value.m3u8,value.flv,value.play_url));}function streamKey(value:Json,index:number){return createHash('sha256').update(streamUrl(value)||String(index)).digest('hex').slice(0,24);}
function contentId(id:string){const encoded=/^live:([^:]+)$/u.exec(id)?.[1];if(encoded===undefined)throw new Error('Content ID is invalid.');return decodeKey(encoded);}function chapterKey(id:string,roomId:string){const prefix=`live:${encodeKey(roomId)}:`;if(!id.startsWith(prefix)||id.length===prefix.length)throw new Error('Chapter ID is invalid.');return id.slice(prefix.length);}
function proxyImage(value:string){if(!safeUrl(value))return null;return requireContext().resource.proxy({kind:'image',url:value,headers:{Referer:web}});}function safeUrl(value:string){try{const url=new URL(value);return(url.protocol==='https:'||url.protocol==='http:')&&url.username===''&&url.password==='';}catch{return false;}}
function cursorPage(cursor:string|null,target:string){if(cursor===null)return 1;const raw=cursor.startsWith(`${target}:`)?cursor.slice(target.length+1):'',page=Number(raw);if(!Number.isSafeInteger(page)||page<2||page>1000)throw new Error('Cursor is invalid.');return page;}function encodeKey(value:string){return Buffer.from(value,'utf8').toString('base64url');}function decodeKey(value:string){if(!/^[A-Za-z0-9_-]+$/u.test(value))throw new Error('Source key is invalid.');return Buffer.from(value,'base64url').toString('utf8');}
function first(...values:unknown[]){return values.find(value=>value!==null&&value!==undefined&&value!=='')??'';}function records(value:unknown):Json[]{return Array.isArray(value)?value.filter(isObject):[];}function object(value:unknown):Json{return isObject(value)?value:{};}function isObject(value:unknown):value is Json{return value!==null&&typeof value==='object'&&!Array.isArray(value);}function text(value:unknown){return typeof value==='string'?value.trim():typeof value==='number'?String(value):'';}function nullable(value:unknown){const result=text(value);return result===''?null:result;}function notNull<T>(value:T|null):value is T{return value!==null;}function clamp(value:number){return Math.max(1,Math.min(50,Math.floor(value)));}function frozen<T>(value:T):T{return Object.freeze(value);}function requireContext():Context{if(context===undefined)throw new Error('Source is not activated.');return context;}
