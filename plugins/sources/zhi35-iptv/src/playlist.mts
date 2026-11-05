/**
 * zhi35 Extended M3U 解析与资源身份。
 * 职责：保留真实频道、分类和台标；仅接受公网 HTTP(S) 资源，不执行 M3U 指令或 EPG 回看模板。
 * 身份：优先上游 tvg-id，否则摘要稳定资源地址；线路摘要排除授权参数，实际播放地址完整保留。
 * 无 IO、无全局可变状态。tvg-name 可能重复，不能合并 CCTV-5 与 CCTV-5+。
 */
import { createHash } from 'node:crypto';

export type Stream = { id: string; url: string; ipv6: boolean };
export type Channel = {
  id: string;
  title: string;
  name: string | null;
  cover: string | null;
  categories: string[];
  streams: Stream[];
};
export type Playlist = { channels: Channel[]; revision: string };
type Entry = { title: string; name: string | null; epgId: string | null; cover: string | null; group: string };

const volatileParameter = /^(?:_+|token|access_token|auth|auth_key|authkey|sign|signature|sig|expires?|expiration|timestamp|ts|t|session|sessionid|livekey|playkey|accountinfo|guardenctype|wssecret|wstime|txsecret|txtime|hdnts)$/iu;

export function digest(value: string): string {
  return createHash('sha256').update(value).digest('hex').slice(0, 24);
}

export function safeHttpUrl(value: string): string | null {
  if (value.length > 8192 || /[\u0000-\u0020\u007f]/u.test(value)) return null;
  try {
    const url = new URL(value);
    if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) return null;
    const host = url.hostname.toLowerCase().replace(/^\[|\]$/gu, '');
    if (!host.includes('.') && !host.includes(':')) return null;
    if (host === 'localhost' || /\.(?:localhost|local|internal)$/u.test(host)) return null;
    if (/^(?:0|10|127)\.|^169\.254\.|^192\.168\.|^172\.(?:1[6-9]|2\d|3[01])\./u.test(host)) return null;
    // Global IPv6 (2000::/3) only; also excludes mapped IPv4 and link-local literals.
    if (host.includes(':') && !/^[23][\da-f]{0,3}:/iu.test(host)) return null;
    url.hash = '';
    return url.href;
  } catch {
    return null;
  }
}

function resourceKey(value: string): string {
  const url = new URL(value);
  for (const key of [...url.searchParams.keys()]) {
    if (volatileParameter.test(key)) url.searchParams.delete(key);
  }
  url.searchParams.sort();
  return url.href;
}

export function parsePlaylist(text: string): Playlist {
  const channels = new Map<string, Channel>();
  let pending: Entry | null = null;
  for (const raw of text.replace(/^\uFEFF/u, '').split(/\r?\n/u)) {
    const line = raw.trim();
    if (line.startsWith('#EXTINF:')) {
      pending = parseEntry(line);
      continue;
    }
    if (!line || line.startsWith('#')) continue;
    const entry = pending;
    pending = null;
    const url = safeHttpUrl(line);
    if (entry === null || url === null) continue;
    const stableResource = resourceKey(url);
    const id = `channel:${digest(entry.epgId === null ? `resource:${stableResource}` : `tvg-id:${entry.epgId}`)}`;
    let channel = channels.get(id);
    if (channel === undefined) {
      channel = { id, title: entry.title, name: entry.name, cover: entry.cover, categories: [], streams: [] };
      channels.set(id, channel);
    }
    if (!channel.categories.includes(entry.group)) channel.categories.push(entry.group);
    channel.cover ??= entry.cover;
    const streamId = `stream:${digest(stableResource)}`;
    const existing = channel.streams.findIndex((stream) => stream.id === streamId);
    const stream = { id: streamId, url, ipv6: new URL(url).hostname.startsWith('[') };
    if (existing < 0) channel.streams.push(stream);
    else channel.streams[existing] = stream;
    if (channels.size > 5000 || channel.streams.length > 64) throw new Error('IPTV 播放列表超出大小限制。');
  }
  const result = [...channels.values()];
  if (result.length === 0) throw new Error('IPTV 播放列表中没有有效频道。');
  // Search/category membership can change without changing a channel's identity.
  const revision = digest(JSON.stringify(result.map(({ id, title, name, categories }) => [id, title, name, categories])));
  return { channels: result, revision };
}

function parseEntry(line: string): Entry | null {
  let quote = '';
  let comma = -1;
  for (let index = 8; index < line.length; index += 1) {
    const char = line[index]!;
    if (quote) { if (char === quote) quote = ''; }
    else if (char === '"' || char === "'") quote = char;
    else if (char === ',') { comma = index; break; }
  }
  if (comma < 0) return null;
  const attributes: Record<string, string> = {};
  const metadata = line.slice(8, comma);
  for (const match of metadata.matchAll(/([\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s]+))/gu)) {
    attributes[match[1]!.toLowerCase()] = (match[2] ?? match[3] ?? match[4] ?? '').trim();
  }
  const title = line.slice(comma + 1).trim() || attributes['tvg-name'] || '';
  if (!title || title.length > 256) return null;
  const group = attributes['group-title'] || '未分组';
  if (group.length > 256) return null;
  return {
    title,
    name: attributes['tvg-name'] && attributes['tvg-name'].length <= 256 ? attributes['tvg-name'] : null,
    epgId: attributes['tvg-id'] || null,
    cover: safeHttpUrl(attributes['tvg-logo'] ?? ''),
    group,
  };
}
