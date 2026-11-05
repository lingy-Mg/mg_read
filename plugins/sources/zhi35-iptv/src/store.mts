/**
 * 四个公开仓库的独立列表缓存；IO 只经 ctx.http，不访问媒体主体。
 * 每来源并行刷新、同仓库地址依次回退；单请求 8 秒、每表最多 3 MiB。
 * 五分钟缓存、整批刷新单飞；失败保留 24 小时内快照且不延长 TTL，自动重试间隔一分钟。
 * 部分失败不阻止其他来源，发现页提示降级状态；全部无有效快照时失败。
 * 每次 activate 新建闭包，旧请求不会写入新激活实例；无磁盘、无定时器和后台任务。
 */
import type { MgReadPluginContext } from '@mgread/source-api';
import { parsePlaylist, type Playlist } from './playlist.mjs';
import { mergePlaylists, type PlaylistProvider, type ProviderPlaylist } from './merge.mjs';

export const homepage = 'https://github.com/zhi35/iptv';
export const playlistUrls = [
  'https://live.zhi35.com/iptv.m3u',
  'https://raw.githubusercontent.com/zhi35/iptv/master/iptv.m3u',
] as const;
export const playlistProviders: readonly PlaylistProvider[] = [
  { id: 'zhi35', title: 'zhi35', urls: playlistUrls },
  { id: 'iptv-org', title: 'iptv-org', urls: ['https://raw.githubusercontent.com/iptv-org/iptv/master/streams/cn.m3u'] },
  { id: 'yuechan', title: 'YueChan', urls: ['https://raw.githubusercontent.com/YueChan/Live/main/GNTV.m3u'] },
  { id: 'free-tv', title: 'Free-TV', urls: ['https://raw.githubusercontent.com/Free-TV/IPTV/master/playlist.m3u8'] },
];
const maximumBytes = 3 * 1024 * 1024;

export function createPlaylistStore(context: MgReadPluginContext, now = Date.now, providers = playlistProviders) {
  const caches = new Map<string, { playlist: Playlist; time: number }>();
  const retryAt = new Map<string, number>();
  let pending: Promise<Playlist> | undefined;
  let merged: { inputs: (Playlist | undefined)[]; playlist: Playlist; notice: string | null } | undefined;
  return { load };

  async function load(refresh = false): Promise<Playlist> {
    if (pending !== undefined) return pending;
    const current = collect(refresh);
    pending = current;
    try { return await current; }
    finally { if (pending === current) pending = undefined; }
  }

  async function collect(refresh: boolean): Promise<Playlist> {
    const inputs = await Promise.all(providers.map((provider) => loadProvider(provider, refresh)));
    const sources = inputs.flatMap((playlist, index): ProviderPlaylist[] => playlist ? [{ provider: providers[index]!, playlist }] : []);
    if (!sources.length) throw new Error('IPTV 播放列表暂时无法获取，请稍后重试。');
    const degraded = providers.filter((provider) => !caches.has(provider.id) || now() - caches.get(provider.id)!.time >= 5 * 60_000);
    const notice = degraded.length ? `${degraded.map((provider) => provider.title).join('、')} 暂时无法更新，正在使用其他来源或已有缓存。` : null;
    if (merged && notice === merged.notice && inputs.every((value, index) => value === merged!.inputs[index])) return merged.playlist;
    const playlist = { ...mergePlaylists(sources), notice };
    merged = { inputs, playlist, notice };
    return playlist;
  }

  async function loadProvider(provider: PlaylistProvider, refresh: boolean): Promise<Playlist | undefined> {
    const cached = caches.get(provider.id);
    if (!refresh && cached && now() - cached.time < 5 * 60_000) return cached.playlist;
    if (!refresh && now() < (retryAt.get(provider.id) ?? 0)) return cached && now() - cached.time < 24 * 60 * 60_000 ? cached.playlist : undefined;
    for (let index = 0; index < provider.urls.length; index += 1) {
      try {
        const response = await context.http.fetch(provider.urls[index]!, {
          headers: { Accept: 'application/vnd.apple.mpegurl,audio/x-mpegurl,text/plain,*/*' },
          signal: AbortSignal.timeout(8000),
        });
        if (!response.ok) {
          await response.body?.cancel();
          throw new Error('playlist_http_failed');
        }
        const playlist = parsePlaylist(await readBoundedText(response));
        caches.set(provider.id, { playlist, time: now() });
        retryAt.delete(provider.id);
        context.log.info(`iptv_playlist_loaded provider=${provider.id} channels=${playlist.channels.length}`);
        return playlist;
      } catch {
        context.log.warn(`iptv_playlist_request_failed provider=${provider.id} endpoint=${index + 1}`);
      }
    }
    retryAt.set(provider.id, now() + 60_000);
    if (cached && now() - cached.time < 24 * 60 * 60_000) {
      context.log.warn(`iptv_playlist_stale provider=${provider.id}`);
      return cached.playlist;
    }
    return undefined;
  }
}

async function readBoundedText(response: Response): Promise<string> {
  if (Number(response.headers.get('content-length')) > maximumBytes) {
    await response.body?.cancel();
    throw new Error('playlist_too_large');
  }
  if (response.body === null) throw new Error('playlist_empty');
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const chunk = await reader.read();
      if (chunk.done) break;
      size += chunk.value.byteLength;
      if (size > maximumBytes) throw new Error('playlist_too_large');
      chunks.push(chunk.value);
    }
    return Buffer.concat(chunks).toString('utf8');
  } finally {
    await reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}
