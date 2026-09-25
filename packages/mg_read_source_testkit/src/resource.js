/**
 * Runtime-owned 资源描述的有界 live 探测。
 *
 * 职责：最多检查少量候选，记录状态/MIME，并只读取首个健康响应块后立即取消。
 */
import { SourceTestFailure, causeSummary } from './diagnostics.js';
import { createRuntimeLikeFetch } from './http.js';
import { createDecipheriv } from 'node:crypto';

export async function probeReachableResource({
  requests,
  fetch: sourceFetch = globalThis.fetch,
  expectedKind = 'image',
  expectedContentType = /^image\//u,
  validatePrefix = null,
  maximumAttempts = 3,
  plugin,
}) {
  if (!Number.isSafeInteger(maximumAttempts) || maximumAttempts < 1 || maximumAttempts > 8) {
    throw new SourceTestFailure('source_resource_attempt_limit_invalid', 'resource', {});
  }
  if (!(expectedContentType instanceof RegExp)) {
    throw new SourceTestFailure('source_resource_content_type_invalid', 'resource', {});
  }
  if (validatePrefix !== null && typeof validatePrefix !== 'function') {
    throw new SourceTestFailure('source_resource_prefix_validator_invalid', 'resource', {});
  }
  const runtimeFetch = createRuntimeLikeFetch(sourceFetch);
  const candidates = (Array.isArray(requests) ? requests : [])
    .filter((request) => request?.kind === expectedKind && typeof request.url === 'string')
    .slice(0, maximumAttempts);
  if (candidates.length === 0) {
    throw new SourceTestFailure('source_resource_missing', 'resource', { expectedKind });
  }

  const attempts = [];
  for (let index = 0; index < candidates.length; index += 1) {
    const request = candidates[index];
    try {
      const response = await fetchRegisteredResource(request, runtimeFetch, plugin);
      const contentType = (response.headers.get('content-type') ?? '').slice(0, 80);
      const attempt = { index: index + 1, url: request.url, status: response.status, contentType };
      expectedContentType.lastIndex = 0;
      if (response.ok && expectedContentType.test(contentType)) {
        const prefix = await readFirstBodyChunk(response);
        const bytesRead = prefix.byteLength;
        if (bytesRead > 0 && (validatePrefix === null || validatePrefix(prefix, contentType, request))) {
          attempts.push(Object.freeze({ ...attempt, bytesRead }));
          return Object.freeze({
            request,
            attempts: Object.freeze(attempts),
            bytesRead,
            contentType,
          });
        }
      } else {
        await response.body?.cancel();
      }
      attempts.push(Object.freeze(attempt));
    } catch (error) {
      attempts.push(Object.freeze({ index: index + 1, url: request.url, ...causeSummary(error) }));
    }
  }
  throw new SourceTestFailure('source_resource_unreachable', 'resource', {
    expectedKind,
    attempts: Object.freeze(attempts),
  });
}

async function fetchRegisteredResource(request, runtimeFetch, plugin) {
  if (request.handler !== undefined) {
    if ((request.resourceKind !== 'image' && request.kind !== 'image') || typeof request.handler !== 'string' ||
        typeof plugin?.getResource !== 'function') throw new Error('invalid source image handler');
    const result = await plugin.getResource(request);
    if (!(result?.bytes instanceof Uint8Array) || result.bytes.byteLength < 1 || result.bytes.byteLength > 24 * 1024 * 1024 ||
        !['image/jpeg', 'image/png', 'image/webp', 'image/gif'].includes(result.mimeType)) throw new Error('invalid source image response');
    return new Response(result.bytes, { headers: { 'content-type': result.mimeType } });
  }
  if (request.resourceTransform === 'sniff-image-content-type-v1') {
    const response = await runtimeFetch(request.url, { headers: request.headers, redirect: 'follow' });
    if (!response.ok || response.body === null) return response;
    const reader = response.body.getReader();
    const first = await reader.read();
    const contentType = first.done ? null : detectedImageContentType(Buffer.from(first.value));
    if (contentType === null) {
      await reader.cancel().catch(() => {});
      throw new Error('invalid transformed resource image');
    }
    await reader.cancel().catch(() => {});
    const headers = new Headers(response.headers);
    headers.set('content-type', contentType);
    return new Response(first.value, {
      status: response.status,
      statusText: response.statusText,
      headers,
    });
  }
  if (request.resourceTransform === 'aes-cbc-prefixed-iv-image-v1') {
    const key = aes256Key(request.resourceTransformKey);
    if (key === null) throw new Error('invalid transformed resource key');
    const response = await runtimeFetch(request.url, { headers: request.headers, redirect: 'follow' });
    if (!response.ok) return response;
    const body = Buffer.from(await response.arrayBuffer());
    if (body.byteLength > 8 * 1024 * 1024) throw new Error('transformed resource body is too large');
    let plain = body;
    if (detectedImageContentType(plain) === null) {
      if (body.byteLength <= 16 || (body.byteLength - 16) % 16 !== 0) {
        throw new Error('invalid transformed resource body');
      }
      const decipher = createDecipheriv('aes-256-cbc', key, body.subarray(0, 16));
      plain = Buffer.concat([decipher.update(body.subarray(16)), decipher.final()]);
    }
    return new Response(plain, { status: 200, headers: { 'content-type': imageContentType(plain) } });
  }
  if (request.resourceTransform === 'aes-cbc-encrypt-then-split-image-v1') {
    const urls = Array.isArray(request.urls) ? request.urls : [];
    if (urls.length < 2 || urls.length > 8 || !urls.every((url) => typeof url === 'string')) {
      throw new Error('invalid transformed resource descriptor');
    }
    const parts = await Promise.all(urls.map((url) => runtimeFetch(url, {
      headers: request.headers,
      redirect: 'follow',
    })));
    const failed = parts.find((part) => !part.ok);
    if (failed !== undefined) return failed;
    const encrypted = Buffer.concat(await Promise.all(parts.map(async (part) => Buffer.from(await part.arrayBuffer()))));
    const decipher = createDecipheriv('aes-128-cbc', Buffer.from('aaaaaaaaaaaaaaaa'), Buffer.from('0123456789aaaaaa'));
    const body = Buffer.concat([decipher.update(encrypted), decipher.final()]);
    return restoredBmiImageResponse(body);
  }
  if (request.resourceTransform !== 'aes-cbc-split-image-v1') {
    return runtimeFetch(request.url, { headers: request.headers, redirect: 'follow' });
  }
  const urls = Array.isArray(request.urls) ? request.urls : [];
  if (urls.length < 2 || urls.length > 8 || !urls.every((url) => typeof url === 'string')) {
    throw new Error('invalid transformed resource descriptor');
  }
  const parts = await Promise.all(urls.map((url) => runtimeFetch(url, {
    headers: request.headers,
    redirect: 'follow',
  })));
  const failed = parts.find((part) => !part.ok);
  if (failed !== undefined) return failed;
  const bodies = await Promise.all(parts.map(async (part) => {
    const body = new Uint8Array(await part.arrayBuffer());
    if (body.byteLength > 8 * 1024 * 1024) throw new Error('transformed resource part is too large');
    const decipher = createDecipheriv('aes-128-cbc', Buffer.from('aaaaaaaaaaaaaaaa'), Buffer.from('0123456789aaaaaa'));
    return Buffer.concat([decipher.update(body), decipher.final()]);
  }));
  const body = Buffer.concat(bodies);
  return restoredBmiImageResponse(body);
}

function restoredBmiImageResponse(body) {
  const type = body[0];
  const restored = type === 0
    ? Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, ...body.subarray(12)])
    : type === 1
      ? Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, ...body.subarray(8)])
      : type === 3
        ? Buffer.from([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, ...body.subarray(6)])
        : type === 4
          ? Buffer.from([0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70, 0x61, 0x76, 0x69, 0x66, ...body.subarray(12)])
          : (() => { throw new Error('transformed resource format is invalid'); })();
  const contentType = type === 1 ? 'image/png' : type === 3 ? 'image/gif' : type === 4 ? 'image/avif' : 'image/jpeg';
  return new Response(restored, { status: 200, headers: { 'content-type': contentType } });
}

function aes256Key(value) {
  if (typeof value !== 'string') return null;
  const key = Buffer.from(value, 'utf8');
  return key.byteLength === 32 ? key : null;
}

function imageContentType(body) {
  const contentType = detectedImageContentType(body);
  if (contentType !== null) return contentType;
  throw new Error('invalid transformed resource image');
}

function detectedImageContentType(body) {
  if (body.subarray(0, 3).equals(Buffer.from([0xff, 0xd8, 0xff]))) return 'image/jpeg';
  if (body.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return 'image/png';
  if (body.subarray(0, 4).toString('ascii') === 'GIF8') return 'image/gif';
  if (body.subarray(0, 4).toString('ascii') === 'RIFF' && body.subarray(8, 12).toString('ascii') === 'WEBP') return 'image/webp';
  if (body.subarray(4, 8).toString('ascii') === 'ftyp') return 'image/avif';
  return null;
}

/**
 * 按内容契约独立探测封面、漫画页图和音视频资源组。
 *
 * `requests` 是测试宿主记录的 Runtime resource.proxy 描述；`projectedUrl`
 * 用于把返回对象里的代理 URL 关联回具体描述，避免用一条可达图片覆盖
 * 其它资源组的验证结果。
 */
export async function probeResourceGroups({
  requests,
  detail,
  discoveryItems = [],
  discoverySurfaces = [],
  searchItems = [],
  contents = [],
  contentKind,
  fetch: sourceFetch = globalThis.fetch,
  plugin,
}) {
  const records = Array.isArray(requests) ? requests : [];
  const allContents = Array.isArray(contents) ? contents : [];
  const kind = contentKind ?? allContents[0]?.contentKind ?? detail?.contentKind ?? null;
  const normalizedDiscoverySurfaces = toArray(discoverySurfaces).length > 0
    ? toArray(discoverySurfaces)
    : [{ name: 'discover', items: toArray(discoveryItems) }];
  const coverSurfaces = [
    ...normalizedDiscoverySurfaces.map((surface, index) => ({
      name: isNonBlank(surface?.name) ? surface.name : `discover.${index + 1}`,
      items: toArray(surface?.items),
      values: toArray(surface?.items).map((item) => item?.coverUrl).filter(isNonBlank),
    })),
    {
      name: 'search',
      items: toArray(searchItems),
      values: toArray(searchItems)
        .map((item) => item?.content?.coverUrl ?? item?.coverUrl)
        .filter(isNonBlank),
    },
    {
      name: 'detail',
      items: detail === null || detail === undefined ? [] : [detail],
      values: [detail?.coverUrl].filter(isNonBlank),
    },
  ].filter((surface) => surface.items.length > 0);
  const groups = {
    cover: await probeResourceSurfaces({
      applicable: coverSurfaces.length > 0,
      surfaces: coverSurfaces.map((surface) => ({
        ...surface,
        kind: 'image',
        mime: /^(image\/|application\/octet-stream)/u,
        validatePrefix: hasImageSignature,
      })),
      records,
      fetch: sourceFetch,
      plugin,
    }),
    comicImages: await probeResourceSurfaces({
      applicable: kind === 'manga',
      surfaces: comicPageSurfaces(allContents),
      records,
      fetch: sourceFetch,
      plugin,
    }),
    audio: await probeResourceSurfaces({
      applicable: kind === 'audio',
      surfaces: mediaSurfaces(allContents, 'audio'),
      records,
      fetch: sourceFetch,
      plugin,
    }),
    video: await probeResourceSurfaces({
      applicable: kind === 'video',
      surfaces: mediaSurfaces(allContents, 'video'),
      records,
      fetch: sourceFetch,
      plugin,
    }),
  };
  return Object.freeze(groups);
}

async function probeResourceSurfaces({ applicable, surfaces, records, fetch, plugin }) {
  if (!applicable) {
    return Object.freeze({ status: 'notTested', applicable: false, candidates: 0, surfaces: Object.freeze([]) });
  }
  if (surfaces.length === 0) {
    return Object.freeze({ status: 'notRegistered', applicable: true, candidates: 0, surfaces: Object.freeze([]) });
  }
  const results = [];
  for (const surface of surfaces) {
    const result = await probeResourceGroup({
      definition: {
        name: surface.name,
        applicable: true,
        kind: surface.kind,
        kinds: surface.kinds,
        mime: surface.mime,
        validatePrefix: surface.validatePrefix,
        values: surface.values,
      },
      records,
      fetch,
      plugin,
    });
    const itemCount = Array.isArray(surface.items) ? surface.items.length : surface.items;
    results.push(Object.freeze({ name: surface.name, items: itemCount, declared: surface.values.length, ...result }));
  }
  const failed = results.find((surface) => surface.status === 'failed');
  const status = failed !== undefined
    ? 'failed'
    : results.every((surface) => surface.status === 'passed')
      ? 'passed'
      : 'notRegistered';
  return Object.freeze({
    status,
    applicable: true,
    candidates: results.reduce((sum, surface) => sum + surface.candidates, 0),
    surfaces: Object.freeze(results),
    ...(failed?.failureCode === undefined ? {} : { failureCode: failed.failureCode }),
  });
}

function comicPageSurfaces(contents) {
  const surfaces = [];
  for (let contentIndex = 0; contentIndex < contents.length; contentIndex += 1) {
    const pages = toArray(contents[contentIndex]?.pages);
    const indexes = [...new Set([0, Math.floor((pages.length - 1) / 2), pages.length - 1])]
      .filter((index) => index >= 0 && index < pages.length);
    for (const pageIndex of indexes) {
      const value = pages[pageIndex]?.url;
      surfaces.push({
        name: `content.${contentIndex + 1}.page.${pageIndex + 1}`,
        items: 1,
        values: isNonBlank(value) ? [value] : [],
        kind: 'image',
        mime: /^(image\/|application\/octet-stream)/u,
        validatePrefix: hasImageSignature,
      });
    }
  }
  return surfaces;
}

function mediaSurfaces(contents, contentKind) {
  return contents.map((content, index) => {
    const value = content?.media?.url;
    return {
      name: `content.${index + 1}.media`,
      items: 1,
      values: isNonBlank(value) ? [value] : [],
      ...(contentKind === 'audio'
        ? { kind: 'audio', mime: /^(audio\/|application\/octet-stream)/u, validatePrefix: hasAudioSignature }
        : {
            kinds: ['video', 'hls'],
            mime: /^(video\/|application\/|text\/plain)/u,
            validatePrefix: hasVideoOrHlsSignature,
          }),
    };
  });
}

async function probeResourceGroup({ definition, records, fetch, plugin }) {
  if (!definition.applicable) {
    return Object.freeze({ status: 'notTested', applicable: false, candidates: 0 });
  }
  if (definition.values.length === 0) {
    return Object.freeze({ status: 'notRegistered', applicable: true, candidates: 0 });
  }
  const candidates = records.filter((request) => {
    const requestKind = String(request?.kind ?? '');
    const kindMatches = definition.kinds?.includes(requestKind) ?? requestKind === definition.kind;
    if (!kindMatches) return false;
    return definition.values.some((value) => requestMatches(value, request));
  }).sort((left, right) => matchRank(left, definition.values) - matchRank(right, definition.values));
  if (candidates.length === 0) {
    return Object.freeze({ status: 'notRegistered', applicable: true, candidates: 0 });
  }
  try {
    const result = await probeReachableResource({
      requests: candidates.map((request) => ({ ...request, resourceKind: request.kind, kind: 'candidate' })),
      fetch,
      plugin,
      expectedKind: 'candidate',
      expectedContentType: definition.mime,
      validatePrefix: definition.validatePrefix,
      maximumAttempts: Math.min(candidates.length, 8),
    });
    return Object.freeze({
      status: 'passed',
      applicable: true,
      candidates: candidates.length,
      attempts: result.attempts,
      bytesRead: result.bytesRead,
      contentType: result.contentType,
    });
  } catch (error) {
    if (!(error instanceof SourceTestFailure)) throw error;
    return Object.freeze({
      status: 'failed',
      applicable: true,
      candidates: candidates.length,
      attempts: error.summary.attempts ?? [],
      failureCode: error.code,
    });
  }
}

function requestMatches(value, request) {
  return value === request?.projectedUrl || value === request?.url;
}

function matchRank(request, values) {
  const index = values.findIndex((value) => requestMatches(value, request));
  return index < 0 ? Number.MAX_SAFE_INTEGER : index;
}

function toArray(value) {
  return Array.isArray(value) ? value : [];
}

function isNonBlank(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

async function readFirstBodyChunk(response) {
  if (response.body === null) return new Uint8Array();
  const reader = response.body.getReader();
  try {
    const first = await reader.read();
    return first.done ? new Uint8Array() : first.value;
  } finally {
    await reader.cancel().catch(() => {});
  }
}

function hasImageSignature(bytes, contentType) {
  const jpeg = startsWith(bytes, [0xff, 0xd8, 0xff]);
  const png = startsWith(bytes, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  const gif = startsWith(bytes, [0x47, 0x49, 0x46, 0x38]);
  const bmp = startsWith(bytes, [0x42, 0x4d]);
  const webp = startsWith(bytes, [0x52, 0x49, 0x46, 0x46]) && startsWith(bytes, [0x57, 0x45, 0x42, 0x50], 8);
  const avif = startsWith(bytes, [0x66, 0x74, 0x79, 0x70], 4);
  if (/image\/(?:jpeg|jpg)/iu.test(contentType)) return jpeg;
  if (/image\/png/iu.test(contentType)) return png;
  if (/image\/gif/iu.test(contentType)) return gif;
  if (/image\/bmp/iu.test(contentType)) return bmp;
  if (/image\/webp/iu.test(contentType)) return webp;
  if (/image\/avif/iu.test(contentType)) return avif;
  return jpeg || png || gif || bmp || webp || avif;
}

function hasAudioSignature(bytes) {
  return startsWith(bytes, [0x49, 0x44, 0x33])
    || startsWith(bytes, [0x66, 0x4c, 0x61, 0x43])
    || startsWith(bytes, [0x4f, 0x67, 0x67, 0x53])
    || (startsWith(bytes, [0x52, 0x49, 0x46, 0x46]) && startsWith(bytes, [0x57, 0x41, 0x56, 0x45], 8))
    || startsWith(bytes, [0x66, 0x74, 0x79, 0x70], 4)
    || hasMpegAudioFrames(bytes);
}

function hasMpegAudioFrames(bytes) {
  const limit = Math.min(bytes.length - 4, 512);
  for (let offset = 0; offset <= limit; offset += 1) {
    const frameLength = mpegAudioFrameLength(bytes, offset);
    if (frameLength === null) continue;
    const nextOffset = offset + frameLength;
    if (mpegAudioFrameLength(bytes, nextOffset) !== null) return true;
  }
  return false;
}

function mpegAudioFrameLength(bytes, offset) {
  if (offset < 0 || offset + 4 > bytes.length || bytes[offset] !== 0xff || (bytes[offset + 1] & 0xe0) !== 0xe0) return null;
  const version = (bytes[offset + 1] >> 3) & 0x03;
  const layer = (bytes[offset + 1] >> 1) & 0x03;
  const bitrateIndex = (bytes[offset + 2] >> 4) & 0x0f;
  const sampleRateIndex = (bytes[offset + 2] >> 2) & 0x03;
  if (version === 1 || layer === 0 || bitrateIndex === 0 || bitrateIndex === 15 || sampleRateIndex === 3) return null;
  const mpeg1Bitrates = {
    1: [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],
    2: [32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384],
    3: [32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448],
  };
  const mpeg2Bitrates = {
    1: [8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
    2: [8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
    3: [32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256],
  };
  const sampleRates = version === 3 ? [44100, 48000, 32000] : version === 2 ? [22050, 24000, 16000] : [11025, 12000, 8000];
  const bitrate = (version === 3 ? mpeg1Bitrates : mpeg2Bitrates)[layer][bitrateIndex - 1] * 1000;
  const sampleRate = sampleRates[sampleRateIndex];
  const padding = (bytes[offset + 2] >> 1) & 0x01;
  if (layer === 3) return Math.floor((12 * bitrate / sampleRate + padding) * 4);
  return Math.floor(((layer === 1 && version !== 3 ? 72 : 144) * bitrate / sampleRate) + padding);
}

function hasVideoOrHlsSignature(bytes, contentType, request) {
  const text = new TextDecoder().decode(bytes.subarray(0, Math.min(bytes.length, 64))).replace(/^\ufeff/u, '').trimStart();
  if (request?.resourceKind === 'hls' || /mpegurl/iu.test(contentType) || text.startsWith('#EXTM3U')) {
    return text.startsWith('#EXTM3U');
  }
  return startsWith(bytes, [0x66, 0x74, 0x79, 0x70], 4)
    || startsWith(bytes, [0x1a, 0x45, 0xdf, 0xa3])
    || startsWith(bytes, [0x46, 0x4c, 0x56])
    || (startsWith(bytes, [0x52, 0x49, 0x46, 0x46]) && startsWith(bytes, [0x41, 0x56, 0x49, 0x20], 8))
    || bytes[0] === 0x47;
}

function startsWith(bytes, signature, offset = 0) {
  if (bytes.length < offset + signature.length) return false;
  return signature.every((value, index) => bytes[offset + index] === value);
}
