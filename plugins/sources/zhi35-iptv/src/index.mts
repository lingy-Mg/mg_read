/**
 * zhi35 IPTV 视频数据源公开入口。
 * 职责：真实分类/频道发现、本地分页检索、频道详情、多线路目录和 Runtime 媒体登记。
 * 生命周期：activate 只注入公开 Context 并替换内存列表缓存；所有请求由调用触发，无启动 IO。
 * 所有权：来源持有频道/线路/游标，Runtime 持有资源流，宿主持有播放器；不生成节目单、回看或热门词。
 * 注意：IPv6 线路依赖用户网络；上游标记 ❌ 和失效资源照实保留，不宣称全源可播。
 */
import type { MgReadPluginContext } from '@mgread/source-api';
import { digest, type Channel, type Playlist, type Stream } from './playlist.mjs';
import { createPlaylistStore } from './store.mjs';
import { resolveMedia } from './media.mjs';

type DiscoveryRequest = { target: string | null; cursor: string | null; collectionId: string | null; pageSize: number };
type SearchRequest = { query: string; cursor: string | null; pageSize: number };
let active: { context: MgReadPluginContext; store: ReturnType<typeof createPlaylistStore> } | undefined;

export async function activate(context: MgReadPluginContext): Promise<void> {
  active = { context, store: createPlaylistStore(context) };
  context.log.info('source_activated');
}

export async function discover(request: DiscoveryRequest) {
  const { context, store } = requireActive();
  if (request.target === null && (request.cursor !== null || request.collectionId !== null)) throw new Error('发现请求无效。');
  const playlist = await store.load();
  const categories = categoryList(playlist);
  const target = request.target ?? 'all';
  const category = categories.find((entry) => entry.target === target);
  if (target !== 'all' && category === undefined) throw new Error('频道分类不存在，请刷新。');
  const channels = target === 'all' ? playlist.channels : playlist.channels.filter((channel) => channel.categories.includes(category!.title));
  const page = paginate(channels, request.cursor, request.pageSize, target, playlist.revision);
  const collectionId = `iptv:${target}`;
  if (request.collectionId !== null && request.collectionId !== collectionId) throw new Error('频道列表标识无效。');
  const items = page.items.map((channel) => ({ content: summary(context, channel), rank: null, metric: null, recommendation: null }));
  const continuation = page.cursor === null ? null : { target, cursor: page.cursor };
  if (request.collectionId !== null) return { kind: 'append' as const, collectionId, items, continuation };
  const listing = {
    type: 'section', id: `${collectionId}:section`, title: category?.title ?? '全部频道', subtitle: null, icon: 'video',
    children: [{ type: 'contentCollection', id: collectionId, layout: 'list', items, continuation }],
  };
  if (request.target !== null) return { kind: 'document' as const, document: { components: [listing] } };
  return {
    kind: 'document' as const,
    document: { components: [
      { type: 'section', id: 'iptv:categories', title: '频道分类', subtitle: null, icon: 'category', children: [
        { type: 'categoryCollection', id: 'iptv:category-list', layout: 'chips', categories: [
          { id: 'all', title: '全部频道', target: 'all', count: playlist.channels.length, url: null, icon: 'video' },
          ...categories,
        ] },
      ] },
      listing,
    ] },
  };
}

export async function search(request: SearchRequest) {
  const query = request.query.normalize('NFKC').trim().toLocaleLowerCase('zh-CN');
  if (!query) {
    if (request.cursor !== null) throw new Error('搜索游标无效。');
    return { items: [], nextCursor: null, totalCount: 0 };
  }
  if (query.length > 256) throw new Error('搜索词过长。');
  const { context, store } = requireActive();
  const playlist = await store.load();
  const terms = query.split(/\s+/u);
  const channels = playlist.channels.filter((channel) => {
    const title = [channel.title, channel.name ?? '', ...channel.categories].join(' ').normalize('NFKC').toLocaleLowerCase('zh-CN');
    return terms.every((term) => title.includes(term));
  });
  const page = paginate(channels, request.cursor, request.pageSize, `search:${digest(query)}`, playlist.revision);
  return { items: page.items.map((channel) => summary(context, channel)), nextCursor: page.cursor, totalCount: channels.length };
}

export async function searchSuggestions(_request: { cursor: string | null; pageSize: number }) {
  return { items: [], nextCursor: null };
}

export async function getDetail(request: { id: string }) {
  const { context, store } = requireActive();
  const channel = locate(await store.load(), request.id);
  return { ...summary(context, channel), aliases: channel.name && channel.name !== channel.title ? [channel.name] : [], catalogUrl: null };
}

export async function getChapters(request: { id: string; refresh?: boolean }) {
  const { store } = requireActive();
  const channel = locate(await store.load(request.refresh === true), request.id);
  const items = channel.streams.map((stream, index) => chapter(channel, stream, index));
  return { items, groups: channel.streams.map((stream, index) => ({
    id: `group:${stream.id}`, title: lineTitle(stream, index), order: index, episodes: [items[index]!],
  })) };
}

export async function getContent(request: { id: string; chapterId: string }) {
  const { context, store } = requireActive();
  const channel = locate(await store.load(true), request.id);
  const stream = channel.streams.find((entry) => chapterId(channel, entry) === request.chapterId);
  if (stream === undefined) throw new Error('直播线路不存在，请刷新频道。');
  const media = await resolveMedia(context, stream.url);
  const headers = { Accept: '*/*' };
  return {
    chapterId: request.chapterId, contentKind: 'video', title: channel.title, updatedAt: null, text: null, pages: [],
    media: {
      url: context.resource.proxy({ kind: media.resourceType, url: media.url, headers }),
      resourceType: media.resourceType, resourcePolicy: 'sessionOnly', expiresAt: null, mimeType: media.mimeType, headers,
    },
  };
}

function summary(context: MgReadPluginContext, channel: Channel) {
  return {
    id: channel.id, title: channel.title, contentKind: 'video', coverOrientation: 'square', author: null, url: null,
    coverUrl: channel.cover === null ? null : context.resource.proxy({ kind: 'image', url: channel.cover, headers: { Accept: 'image/*' } }),
    description: channel.streams.every((stream) => stream.ipv6) ? '此频道的直播线路需要 IPv6 网络。' : null,
    language: null, status: 'ongoing', access: 'unknown', wordCount: null, chapterCount: channel.streams.length,
    publishedAt: null, updatedAt: null, latestChapter: null, categories: channel.categories, tags: [], attributes: [],
  };
}

function chapterId(channel: Channel, stream: Stream): string { return `${channel.id}:${stream.id}`; }
function lineTitle(stream: Stream, index: number): string { return `线路 ${index + 1}${stream.ipv6 ? ' · IPv6' : ''}`; }
function chapter(channel: Channel, stream: Stream, index: number) {
  return {
    id: chapterId(channel, stream), title: '直播', order: 0, url: null, volumeTitle: lineTitle(stream, index),
    wordCount: null, updatedAt: null, isLocked: false, attributes: [],
  };
}

function locate(playlist: Playlist, id: string): Channel {
  if (!/^channel:[\da-f]{24}$/u.test(id)) throw new Error('频道标识无效。');
  const channel = playlist.channels.find((entry) => entry.id === id);
  if (channel === undefined) throw new Error('上游已移除此频道，请刷新播放列表。');
  return channel;
}

function categoryList(playlist: Playlist) {
  const titles = [...new Set(playlist.channels.flatMap((channel) => channel.categories))];
  if (titles.length > 32) throw new Error('频道分类超出大小限制。');
  return titles.map((title) => ({
    id: digest(title), title, target: `category:${digest(title)}`,
    count: playlist.channels.filter((channel) => channel.categories.includes(title)).length, url: null, icon: 'video',
  }));
}

function paginate<T>(items: T[], cursor: string | null, pageSize: number, scope: string, revision: string) {
  if (!Number.isSafeInteger(pageSize) || pageSize < 1) throw new Error('分页大小无效。');
  const size = Math.min(50, pageSize);
  const key = digest(`${scope}:${revision}`);
  let offset = 0;
  if (cursor !== null) {
    if (cursor.length > 512 || !/^[\w-]+$/u.test(cursor)) throw new Error('列表游标无效。');
    let value: unknown;
    try { value = JSON.parse(Buffer.from(cursor, 'base64url').toString('utf8')); }
    catch { throw new Error('列表游标无效。'); }
    if (!Array.isArray(value) || value.length !== 3 || value[0] !== key || value[1] !== size ||
        !Number.isSafeInteger(value[2]) || value[2] < 1 || value[2] >= items.length || value[2] % size !== 0) {
      throw new Error('列表已更新或游标无效，请刷新。');
    }
    offset = value[2] as number;
  }
  const page = items.slice(offset, offset + size);
  const next = offset + page.length;
  return { items: page, cursor: next < items.length ? Buffer.from(JSON.stringify([key, size, next])).toString('base64url') : null };
}

function requireActive() {
  if (active === undefined) throw new Error('数据源尚未激活。');
  return active;
}
