/**
 * IPTV 列表请求与激活周期内缓存。
 * IO 只经公开 ctx.http，优先上游加速地址，失败后读取同一仓库原文件；不访问媒体主体。
 * 列表最多 2 MiB、每个请求 12 秒；五分钟缓存、单飞刷新，失败可读 24 小时内的旧快照且不延长 TTL。
 * 每次 activate 新建闭包，旧请求不会写入新激活实例；无磁盘、无定时器和后台任务。
 */
import type { MgReadPluginContext } from '@mgread/source-api';
import { parsePlaylist, type Playlist } from './playlist.mjs';

export const homepage = 'https://github.com/zhi35/iptv';
export const playlistUrls = [
  'https://live.zhi35.com/iptv.m3u',
  'https://raw.githubusercontent.com/zhi35/iptv/master/iptv.m3u',
] as const;
const maximumBytes = 2 * 1024 * 1024;

export function createPlaylistStore(context: MgReadPluginContext, now = Date.now) {
  let cached: { playlist: Playlist; time: number } | undefined;
  let pending: Promise<Playlist> | undefined;
  return { load };

  async function load(refresh = false): Promise<Playlist> {
    if (!refresh && cached !== undefined && now() - cached.time < 5 * 60_000) return cached.playlist;
    if (pending !== undefined) return pending;
    const current = fetchPlaylist().catch((error: unknown) => {
      if (cached !== undefined && now() - cached.time < 24 * 60 * 60_000) {
        context.log.warn('iptv_playlist_stale');
        return cached.playlist;
      }
      throw error;
    });
    pending = current;
    try { return await current; }
    finally { if (pending === current) pending = undefined; }
  }

  async function fetchPlaylist(): Promise<Playlist> {
    for (let index = 0; index < playlistUrls.length; index += 1) {
      try {
        const response = await context.http.fetch(playlistUrls[index]!, {
          headers: { Accept: 'application/vnd.apple.mpegurl,audio/x-mpegurl,text/plain,*/*' },
          signal: AbortSignal.timeout(12_000),
        });
        if (!response.ok) {
          await response.body?.cancel();
          throw new Error('playlist_http_failed');
        }
        const playlist = parsePlaylist(await readBoundedText(response));
        cached = { playlist, time: now() };
        context.log.info(`iptv_playlist_loaded channels=${playlist.channels.length} endpoint=${index + 1}`);
        return playlist;
      } catch {
        context.log.warn(`iptv_playlist_request_failed endpoint=${index + 1}`);
      }
    }
    throw new Error('IPTV 播放列表暂时无法获取，请稍后重试。');
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
