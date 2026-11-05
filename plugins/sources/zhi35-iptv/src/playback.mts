/**
 * 自动线路的有界打开前选择；明确选择的线路只解析本身，绝不静默换台/换线路。
 * 明示“含直连”的自动入口按地址尝试默认/直连，优先最近成功组合；共八次、十秒、单次四秒。
 * 成功仅代表 HLS 元数据或容器识别，不代表媒体分片、解码成功；播放后断流由用户手动切换。
 * 每次 activate 创建独立偏好，最多 512 个频道，不落盘、不改变用户代理设置、不缓存视频主体。
 */
import type { MgReadPluginContext } from '@mgread/source-api';
import type { Channel, Stream } from './playlist.mjs';
import { resolveMedia } from './media.mjs';

export function createPlaybackResolver(context: MgReadPluginContext) {
  const preferred = new Map<string, string>();
  return { resolve };

  async function resolve(channel: Channel, selected?: Stream) {
    if (selected) {
      const media = await resolveMedia(context, selected.url, channel.title);
      remember(channel.id, selected.id);
      return media;
    }
    const last = preferred.get(channel.id);
    const candidates = channel.streams.flatMap((stream) => [
      { stream, proxyMode: undefined }, { stream, proxyMode: 'direct' as const },
    ]).sort((a, b) => Number(`${b.stream.id}:${b.proxyMode ?? 'default'}` === last) - Number(`${a.stream.id}:${a.proxyMode ?? 'default'}` === last)).slice(0, 8);
    const deadline = AbortSignal.timeout(10_000);
    let attempted = 0;
    for (const { stream, proxyMode } of candidates) {
      if (deadline.aborted) break;
      attempted += 1;
      try {
        const media = await resolveMedia(context, stream.url, channel.title, AbortSignal.any([deadline, AbortSignal.timeout(4000)]), proxyMode);
        remember(channel.id, stream.id, proxyMode);
        context.log.info(`iptv_auto_line_resolved attempts=${attempted} direct=${proxyMode === 'direct'}`);
        return { ...media, ...(proxyMode ? { proxyMode } : {}) };
      } catch { context.log.warn(`iptv_auto_line_failed attempt=${attempted}`); }
    }
    return context.errors.raise({
      code: 'source_media_resolution_failed', message: `${channel.title}：已尝试 ${attempted} 次线路连接，暂时无法打开直播。`,
      annotation: '请在“选集 / 线路”中手动选择其他线路，或稍后刷新；自动选择只检查打开前的直播清单。',
    });
  }

  function remember(channelId: string, streamId: string, proxyMode?: 'direct') {
    preferred.delete(channelId);
    preferred.set(channelId, `${streamId}:${proxyMode ?? 'default'}`);
    if (preferred.size > 512) preferred.delete(preferred.keys().next().value!);
  }
}
