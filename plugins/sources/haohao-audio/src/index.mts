/**
 * 昊昊享听原生数据源：将用户提供的明文接口规则迁移至公开 Source API。
 * 职责：发现、搜索、专辑详情、完整目录和按需解析音频；不执行导入规则中的脚本或动作。
 * IO：api-preview.toulaopao.cc；上下文/匿名会话由 activate 重置，不保留媒体 URL。
 * 稳定身份：album 使用上游专辑 ID，chapter 使用章节 ID；播放时从当前完整目录查回 index。
 * 注意：上游还提供真实 rank/category/album 接口，因此不用原规则的关键词栏目和搜索缓存补详情。
 */
import type {MgReadPluginContext, PluginChaptersRequest} from '@mgread/source-api';
import {initialize, json, records, summaries, summary, album, native, natural, position, window, chapters, remoteChapters, catalogResult, media, ctx, type SearchRequest} from './protocol.mjs';
export {discover} from './discovery.mjs';
export const deferredGroups = true;
export function activate(context: MgReadPluginContext) { initialize(context, 'https://api-preview.toulaopao.cc/api/h5/listening/', 'https://tingyou.fm/'); }
export async function search(request: SearchRequest) {
  const query = request.query.trim(), scope = 'search:' + query;
  if (!query) return {items: [], nextCursor: null, totalCount: 0};
  const {page} = position(request.cursor, scope), data = await json('search', {keyword: query, page});
  if (!Array.isArray(data.results)) throw new Error('Invalid search response.');
  const raw = records(data.results);
  return {...window(summaries(raw), scope, request.cursor, request.pageSize, data.has_more === true && raw.length > 0), totalCount: natural(data.total)};
}
export async function searchSuggestions() { return {items: [], nextCursor: null}; }
export async function getDetail(request: {id: string}) {
  const id = album(request.id), data = await json('album/' + id);
  if (data.available === false) ctx().errors.raise('source_access_blocked');
  if (native(data.id) !== id) throw new Error('Detail album ID mismatch.');
  return {...summary(data), aliases: [], catalogUrl: 'https://api-preview.toulaopao.cc/api/h5/listening/chapters/' + id};
}
export async function getChapters(request: PluginChaptersRequest) {
  const id = album(request.id), values = await remoteChapters(id, request.refresh);
  return catalogResult(request, chapters(id, values, 'chapter'));
}
export async function getContent(request: {id: string; chapterId: string}) {
  const id = album(request.id), match = new RegExp('^chapter:' + id + ':(\\d{1,20})$', 'u').exec(request.chapterId);
  if (!match) throw new Error('Invalid chapter ID.');
  const values = await remoteChapters(id), item = values.find(v => String(v.id) === match[1]);
  if (!item || natural(item.index) === null) throw new Error('Chapter is unavailable.');
  if (item.is_locked === true || item.locked === true || item.is_vip === true) ctx().errors.raise('source_access_blocked');
  const data = await json('play', {album_id: id, chapter_idx: natural(item.index)});
  return media(request.chapterId, data.play_url, item.title);
}
