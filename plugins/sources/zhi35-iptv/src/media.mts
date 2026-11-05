/**
 * 直播资源类型与 Runtime 代理描述。
 * HLS 在播放前有界核对清单与 HTTP 状态，失效地址通过公开来源错误上报；FLV/MP4 不预读。
 * 无扩展名的跳转入口只取至多 1 KiB 前缀识别 HLS/容器并立即取消。
 * 不缓存或返回媒体字节，不使用伪造 UA/Cookie；实际地址的授权查询参数完整保留。
 */
import type { MgReadPluginContext } from '@mgread/source-api';
import { safeHttpUrl } from './playlist.mjs';

type Media = { url: string; resourceType: 'hls' | 'video'; mimeType: string | null; proxyMode?: 'direct' };

export async function resolveMedia(context: MgReadPluginContext, url: string, title = '该频道', signal?: AbortSignal, proxyMode?: 'direct'): Promise<Media> {
  const path = new URL(url).pathname;
  if (/\.m3u8?$/iu.test(path)) return inspectHls(context, url, title, signal, proxyMode);
  if (/\.flv$/iu.test(path)) return { url, resourceType: 'video', mimeType: 'video/x-flv' };
  if (/\.mp4$/iu.test(path)) return { url, resourceType: 'video', mimeType: 'video/mp4' };
  const response = await context.http.fetch(url, {
    headers: { Accept: '*/*', Range: 'bytes=0-1023' },
    signal: requestSignal(10_000, signal),
    ...(proxyMode ? { proxyMode } : {}),
  });
  const finalUrl = safeHttpUrl(response.url || url);
  const reader = response.body?.getReader();
  try {
    if (!response.ok || reader === undefined || finalUrl === null) throw new Error('直播线路暂时无法解析。');
    const chunks: Uint8Array[] = [];
    let size = 0;
    while (size < 1024) {
      const chunk = await reader.read();
      if (chunk.done) break;
      const prefix = chunk.value.subarray(0, 1024 - size);
      chunks.push(prefix);
      size += prefix.byteLength;
      if (size >= 8) break;
    }
    const bytes = Buffer.concat(chunks);
    if (bytes.toString('utf8').replace(/^\uFEFF/u, '').trimStart().startsWith('#EXTM3U')) {
      return { url: finalUrl, resourceType: 'hls', mimeType: 'application/vnd.apple.mpegurl' };
    }
    if (bytes.subarray(0, 3).toString('ascii') === 'FLV') return { url: finalUrl, resourceType: 'video', mimeType: 'video/x-flv' };
    if (bytes.subarray(4, 8).toString('ascii') === 'ftyp') return { url: finalUrl, resourceType: 'video', mimeType: 'video/mp4' };
    const mime = (response.headers.get('content-type') ?? '').split(';')[0]!.trim().toLowerCase();
    if (bytes.length > 0 && /^video\//u.test(mime)) return { url: finalUrl, resourceType: 'video', mimeType: mime };
    throw new Error('直播线路没有返回可识别的视频或 HLS。');
  } finally {
    if (reader !== undefined) { await reader.cancel().catch(() => {}); reader.releaseLock(); }
  }
}

async function inspectHls(context: MgReadPluginContext, url: string, title: string, signal?: AbortSignal, proxyMode?: 'direct'): Promise<Media> {
  let response: Response;
  try {
    response = await context.http.fetch(url, {
      headers: { Accept: 'application/vnd.apple.mpegurl,application/x-mpegurl,text/plain,*/*' },
      signal: requestSignal(8000, signal),
      ...(proxyMode ? { proxyMode } : {}),
    });
  } catch {
    return failHls(context, url, title, '直播服务器连接失败或超时。');
  }
  if (!response.ok) {
    await response.body?.cancel().catch(() => {});
    return failHls(context, url, title, `直播地址请求失败（HTTP ${response.status}）。`, [401, 403, 451].includes(response.status));
  }
  if (safeHttpUrl(response.url || url) === null || response.body === null) {
    await response.body?.cancel().catch(() => {});
    return failHls(context, url, title, '直播服务器没有提供有效清单。');
  }
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  let valid = false;
  try {
    while (size < 8192) {
      const chunk = await reader.read();
      if (chunk.done) break;
      const part = chunk.value.subarray(0, 8192 - size);
      chunks.push(part);
      size += part.byteLength;
      const text = Buffer.concat(chunks).toString('utf8').replace(/^\uFEFF/u, '').trimStart();
      if (text.includes('\n') && text.split(/\r?\n/u)[0]?.trim() !== '#EXTM3U') break;
      if (/^#EXTM3U\r?\n/u.test(text) && /^#EXT-X-(?:TARGETDURATION|STREAM-INF):/mu.test(text)) { valid = true; break; }
    }
  } catch {
    return failHls(context, url, title, '直播清单读取失败或超时。');
  } finally { await reader.cancel().catch(() => {}); reader.releaseLock(); }
  if (!valid) return failHls(context, url, title, '直播地址没有返回有效的 HLS 清单。');
  // Runtime 独立执行重定向，避免把预检取得的临时会话地址当成长期播放地址。
  return { url, resourceType: 'hls', mimeType: 'application/vnd.apple.mpegurl' };
}

function failHls(context: MgReadPluginContext, url: string, title: string, reason: string, blocked = false): never {
  return context.errors.raise({
    code: blocked ? 'source_access_blocked' : 'source_media_resolution_failed',
    message: `${title}：${reason}`,
    annotation: `${new URL(url).hostname.startsWith('[') ? '这条上游线路使用 IPv6。' : ''}当前直播尚未成功打开；请更换有效线路，或等待上游更新。`,
  });
}

function requestSignal(timeout: number, signal?: AbortSignal): AbortSignal {
  return signal ? AbortSignal.any([AbortSignal.timeout(timeout), signal]) : AbortSignal.timeout(timeout);
}
