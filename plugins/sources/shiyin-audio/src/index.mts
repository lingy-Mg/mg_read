/**
 * 十音·有声专辑原生数据源；十音检索/音轨与听友发现/目录分别保持公开 HTTP 链路。
 * 生命周期：activate 重置 Context 和匿名会话；无账号提取、文件下载或媒体 URL 缓存。
 * IO：api.365ting.com 搜索及音轨，fmfm.tingyou.fm 提供真实榜单、分类、详情和备用播放。
 * 稳定身份：book_id 标识专辑；目录明确区分上游 chapter ID 与十音 track ID，不把临时 URL 作 ID。
 * 注意：保留完整标题及所有音轨，不按关键词/时长删除章节，不复制旧规则的离线书名封面表。
 * 十音目录失败时允许回到同一 book_id 的听友目录；既有 chapter ID 仍固定走其原提供方。
 * 站内音轨仅用 HEAD 检查可达性；明确失败时以相同标题和可用的 track_no 核对听友章节后备用播放。
 */
import type {MgReadPluginContext, PluginChaptersRequest} from '@mgread/source-api';
import {initialize, json, jsonUrl, object, records, summaries, summary, album, native, natural, position, window, chapters, remoteChapters, catalogResult, snapshot, media, ctx, text, type Json, type SearchRequest} from './protocol.mjs';
export {discover} from './discovery.mjs';
export const deferredGroups = true;
const ty = 'https://api.365ting.com';
export function activate(context: MgReadPluginContext) { initialize(context, 'https://fmfm.tingyou.fm/listening-api/', 'https://fmfm.tingyou.fm/'); }
async function searchPage(query: string, page: number) {
  const result = await jsonUrl(ty + '/tingyou-app/search?keyword=' + encodeURIComponent(query) + '&page=' + page);
  if (!object(result.data) || !Array.isArray(result.data.items)) throw new Error('Invalid ten-audio search response.');
  return result.data;
}
export async function search(request: SearchRequest) {
  const query = request.query.trim(), scope = 'search:' + query;
  if (!query) return {items: [], nextCursor: null, totalCount: 0};
  const {page} = position(request.cursor, scope);
  if (page % 2 !== 1) throw new Error('Invalid search batch cursor.');
  const primary = await Promise.allSettled([searchPage(query, page), searchPage(query, page + 1)]);
  const map = new Map<string, Json>();
  for (const result of primary) if (result.status === 'fulfilled') for (const item of records(result.value.items)) {
    const id = text(item.book_id ?? item.id);
    if (!/^\d{1,20}$/u.test(id)) continue;
    if (!map.has(id) || (Number(item.album_id) > 0 && !(Number(map.get(id)!.album_id) > 0))) map.set(id, item);
  }
  // An unavailable/short primary result uses the supplied public fallback, not a fabricated recommendation.
  const lastPrimary = primary[1]!;
  let more = lastPrimary.status === 'fulfilled' ? lastPrimary.value.has_more === true : primary[0]?.status === 'fulfilled' && primary[0].value.has_more === true;
  if (map.size < 5 || primary.some(r => r.status === 'rejected')) {
    const fallback = await Promise.allSettled([json('search', {keyword: query, page}), json('search', {keyword: query, page: page + 1})]);
    const completed = [...primary, ...fallback].filter(r => r.status === 'fulfilled');
    if (completed.length === 0) throw new Error('Both audio search providers failed.');
    for (const result of fallback) if (result.status === 'fulfilled') {
      if (!Array.isArray(result.value.results)) throw new Error('Invalid fallback search response.');
      for (const item of records(result.value.results)) { const id = text(item.id); if (/^\d{1,20}$/u.test(id) && !map.has(id)) map.set(id, item); }
    }
    const lastFallback = fallback[1]!;
    more ||= lastFallback.status === 'fulfilled' ? lastFallback.value.has_more === true : fallback[0]?.status === 'fulfilled' && fallback[0].value.has_more === true;
    // Never advance past an unread page in both providers.
    for (let i = 0; i < 2; i++) if (primary[i]!.status === 'rejected' && fallback[i]!.status === 'rejected') throw new Error('Audio search page is unavailable.');
  }
  const score = (item: Json) => { const title = text(item.title).toLowerCase(), q = query.toLowerCase(); return title === q ? 3 : title.startsWith(q) ? 2 : title.includes(q) ? 1 : 0; };
  const values = [...map.values()].sort((a, b) => score(b) - score(a) || Number(Number(b.album_id) > 0) - Number(Number(a.album_id) > 0));
  return {...window(summaries(values), scope, request.cursor, request.pageSize, more && values.length > 0, 2), totalCount: null};
}
export async function searchSuggestions() { return {items: [], nextCursor: null}; }
async function lookup(id: string, refresh = false): Promise<Json | null> {
  return snapshot('lookup:' + id, async () => {
    const data = await searchPage(id, 1);
    return records(data.items).find(item => text(item.book_id ?? item.id) === id) ?? null;
  }, refresh);
}
async function localTracks(id: string, refresh = false): Promise<Json[] | null> {
  return snapshot('local-catalog:' + id, async () => {
    const metadata = await lookup(id, refresh);
    if (!metadata || !(Number(metadata.album_id) > 0)) return null;
    const data = await jsonUrl(ty + '/api/albums/' + native(metadata.album_id) + '/tracks?user_id=-1');
    if (!Array.isArray(data.data)) throw new Error('Invalid ten-audio catalog.');
    const tracks = records(data.data).map(value => ({id: value.id, title: value.title, duration: value.duration,
      track_no: value.track_no, is_locked: value.is_locked, locked: value.locked, is_vip: value.is_vip}));
    const total = natural(data.total);
    if (total !== null && tracks.length !== total) throw new Error('Incomplete ten-audio catalog.');
    chapters(id, tracks, 'track');
    if (tracks.every(v => natural(v.track_no) !== null) && new Set(tracks.map(v => Number(v.track_no))).size === tracks.length) tracks.sort((a, b) => Number(a.track_no) - Number(b.track_no));
    return tracks;
  }, refresh);
}
export async function getDetail(request: {id: string}) {
  const id = album(request.id);
  let catalogUrl = 'https://fmfm.tingyou.fm/listening-api/chapters/' + id;
  let data: Json;
  try {
    data = await json('album/' + id);
    if (native(data.id) !== id || data.available === false) throw new Error('Album is unavailable.');
  } catch {
    const local = await lookup(id);
    if (!local || !(Number(local.album_id) > 0)) throw new Error('Album detail is unavailable.');
    data = local;
    catalogUrl = ty + '/api/albums/' + native(local.album_id) + '/tracks?user_id=-1';
  }
  return {...summary(data), aliases: [], catalogUrl};
}
export async function getChapters(request: PluginChaptersRequest) {
  const id = album(request.id);
  if (request.groupId?.startsWith('range:chapter:' + id + ':')) return catalogResult(request, chapters(id, await remoteChapters(id, request.refresh), 'chapter'));
  if (request.groupId?.startsWith('range:track:' + id + ':')) {
    const tracks = await localTracks(id, request.refresh);
    if (!tracks?.length) throw new Error('Ten-audio group is unavailable.');
    return catalogResult(request, chapters(id, tracks, 'track'));
  }
  let tracks: Json[] | null = null;
  try { tracks = await localTracks(id, request.refresh); } catch { ctx().log.warn('local_catalog_unavailable'); }
  if (tracks?.length) return catalogResult(request, chapters(id, tracks, 'track'));
  return catalogResult(request, chapters(id, await remoteChapters(id, request.refresh), 'chapter'));
}
export async function getContent(request: {id: string; chapterId: string}) {
  const id = album(request.id), match = new RegExp('^(chapter|track):' + id + ':(\\d{1,20})$', 'u').exec(request.chapterId);
  if (!match) throw new Error('Invalid chapter ID.');
  if (match[1] === 'track') {
    const values = await localTracks(id), item = values?.find(v => String(v.id) === match[2]);
    if (!item) throw new Error('Ten-audio track is unavailable.');
    if (item.is_locked === true || item.locked === true || item.is_vip === true) ctx().errors.raise('source_access_blocked');
    const upstream = ty + '/api/audio/' + native(item.id);
    if (await localAudioAvailable(upstream)) return media(request.chapterId, upstream, item.title);
    const remote = await remoteChapters(id), trackNo = natural(item.track_no);
    const matches = remote.filter(v => text(v.title) === text(item.title) && (trackNo === null || natural(v.index) === trackNo));
    if (matches.length !== 1) ctx().errors.raise('source_media_resolution_failed');
    const fallback = matches[0]!;
    if (fallback.is_locked === true || fallback.locked === true || fallback.is_vip === true) ctx().errors.raise('source_access_blocked');
    const data = await json('play', {album_id: id, chapter_idx: natural(fallback.index)});
    ctx().log.warn('local_audio_unavailable_using_matched_chapter');
    return media(request.chapterId, data.play_url, item.title);
  }
  const values = await remoteChapters(id), item = values.find(v => String(v.id) === match[2]);
  if (!item || natural(item.index) === null) throw new Error('Chapter is unavailable.');
  if (item.is_locked === true || item.locked === true || item.is_vip === true) ctx().errors.raise('source_access_blocked');
  const data = await json('play', {album_id: id, chapter_idx: natural(item.index)});
  return media(request.chapterId, data.play_url, item.title);
}
async function localAudioAvailable(url: string) {
  try {
    const response = await ctx().http.fetch(url, {method: 'HEAD', headers: {Referer: 'https://fmfm.tingyou.fm/'}, signal: AbortSignal.timeout(8000)});
    await response.body?.cancel();
    return response.ok || response.status === 405 || response.status === 501;
  } catch { return false; }
}
