/** IPTV 专属 HLS 补充取证：主清单/variant/key/segment 有界探测，不下载完整直播流。 */
import assert from 'node:assert/strict';
import { safeHttpUrl } from '../dist/playlist.mjs';

export async function probeHls(request, fetch) {
  const stages = [];
  let current = request.url;
  for (let depth = 0; depth < 3; depth += 1) {
    const manifest = await prefix(current, request.headers, 65536, fetch);
    const text = manifest.bytes.toString('utf8').replace(/^\uFEFF/u, '').trim();
    assert.ok(text.startsWith('#EXTM3U'), 'hls_manifest_signature_invalid');
    const lines = text.split(/\r?\n/u).map((line) => line.trim());
    stages.push({ stage: depth === 0 ? 'playlist' : 'variant', status: manifest.status, bytes: manifest.bytes.length });
    const uri = lines.find((line) => line && !line.startsWith('#'));
    assert.ok(uri, 'hls_manifest_uri_missing');
    if (text.includes('#EXT-X-STREAM-INF:')) {
      current = checked(new URL(uri, manifest.url).href);
      continue;
    }
    const keyLine = lines.find((line) => line.startsWith('#EXT-X-KEY:') && !line.includes('METHOD=NONE'));
    if (keyLine) {
      assert.ok(keyLine.includes('METHOD=AES-128'), 'hls_key_method_not_tested');
      const keyUri = /URI="([^"]+)"/u.exec(keyLine)?.[1];
      assert.ok(keyUri, 'hls_key_uri_missing');
      const key = await prefix(checked(new URL(keyUri, manifest.url).href), request.headers, 17, fetch);
      assert.equal(key.bytes.length, 16, 'hls_key_size_invalid');
      stages.push({ stage: 'key', status: key.status, bytes: key.bytes.length });
    }
    const segment = await prefix(checked(new URL(uri, manifest.url).href), { ...request.headers, Range: 'bytes=0-4095' }, 4096, fetch);
    assert.ok(segment.bytes.length > 0, 'hls_segment_empty');
    assert.ok(!segment.contentType.includes('text/html'), 'hls_segment_html');
    if (!keyLine) {
      const mp4 = ['ftyp', 'styp', 'moof', 'sidx'].includes(segment.bytes.subarray(4, 8).toString('ascii'));
      assert.ok(segment.bytes[0] === 0x47 || mp4, 'hls_segment_signature_invalid');
    }
    stages.push({ stage: 'segment', status: segment.status, bytes: segment.bytes.length });
    return { status: 'passed', stages };
  }
  throw new Error('hls_variant_depth_exceeded');
}

async function prefix(url, headers, limit, fetch) {
  const response = await fetch(url, { headers });
  if (!response.ok || response.body === null) {
    await response.body?.cancel();
    throw new Error(`upstream_http_${response.status}`);
  }
  const reader = response.body.getReader();
  const chunks = [];
  let size = 0;
  try {
    while (size < limit) {
      const chunk = await reader.read();
      if (chunk.done) break;
      const part = chunk.value.subarray(0, limit - size);
      chunks.push(part);
      size += part.length;
    }
    return { bytes: Buffer.concat(chunks), status: response.status, url: checked(response.url || url), contentType: response.headers.get('content-type') ?? '' };
  } finally { await reader.cancel().catch(() => {}); reader.releaseLock(); }
}

function checked(url) {
  const result = safeHttpUrl(url);
  assert.ok(result, 'upstream_url_invalid');
  return result;
}

export function failureCode(error) {
  const code = error?.cause?.code ?? error?.code;
  if (typeof code === 'string' && code !== 'ERR_ASSERTION') return code.slice(0, 100);
  const message = String(error?.message ?? 'unknown');
  return /^(?:upstream_http_\d{3}|hls_[a-z_]+)$/u.test(message) ? message : error?.name ?? 'Error';
}

export function sanitize(value) {
  return JSON.parse(JSON.stringify(value, (key, item) => {
    if (['url', 'projectedUrl', 'headers', 'request', 'stack', 'message', 'detail'].includes(key)) return undefined;
    return item;
  }));
}
