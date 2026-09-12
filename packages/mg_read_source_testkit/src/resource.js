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
  maximumAttempts = 3,
}) {
  if (!Number.isSafeInteger(maximumAttempts) || maximumAttempts < 1 || maximumAttempts > 8) {
    throw new SourceTestFailure('source_resource_attempt_limit_invalid', 'resource', {});
  }
  if (!(expectedContentType instanceof RegExp)) {
    throw new SourceTestFailure('source_resource_content_type_invalid', 'resource', {});
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
      const response = await fetchRegisteredResource(request, runtimeFetch);
      const contentType = (response.headers.get('content-type') ?? '').slice(0, 80);
      const attempt = { index: index + 1, url: request.url, status: response.status, contentType };
      expectedContentType.lastIndex = 0;
      if (response.ok && expectedContentType.test(contentType)) {
        const bytesRead = await readFirstBodyChunk(response);
        if (bytesRead > 0) {
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

async function fetchRegisteredResource(request, runtimeFetch) {
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
  searchItems = [],
  contents = [],
  contentKind,
  fetch: sourceFetch = globalThis.fetch,
}) {
  const records = Array.isArray(requests) ? requests : [];
  const allContents = Array.isArray(contents) ? contents : [];
  const kind = contentKind ?? allContents[0]?.contentKind ?? detail?.contentKind ?? null;
  const coverValues = [
    detail?.coverUrl,
    ...toArray(discoveryItems).map((item) => item?.coverUrl),
    ...toArray(searchItems).map((item) => item?.content?.coverUrl ?? item?.coverUrl),
  ].filter(isNonBlank);
  const pageValues = allContents.flatMap((content) =>
    Array.isArray(content?.pages) ? content.pages.map((page) => page?.url) : []
  ).filter(isNonBlank);
  const mediaValues = allContents.map((content) => content?.media?.url).filter(isNonBlank);

  const definitions = [
    { name: 'cover', applicable: coverValues.length > 0, kind: 'image', mime: /^image\//u, values: coverValues },
    { name: 'comicImages', applicable: kind === 'manga' && pageValues.length > 0, kind: 'image', mime: /^image\//u, values: pageValues },
    { name: 'audio', applicable: kind === 'audio', kind: 'audio', mime: /^(audio\/|application\/octet-stream)/u, values: mediaValues },
    { name: 'video', applicable: kind === 'video', kinds: ['video', 'hls'], mime: /^(video\/|application\/|text\/plain)/u, values: mediaValues },
  ];
  const groups = {};
  for (const definition of definitions) {
    groups[definition.name] = await probeResourceGroup({
      definition,
      records,
      fetch: sourceFetch,
    });
  }
  return Object.freeze(groups);
}

async function probeResourceGroup({ definition, records, fetch }) {
  if (!definition.applicable) {
    return Object.freeze({ status: 'notTested', applicable: false, candidates: 0 });
  }
  const candidates = records.filter((request) => {
    const requestKind = String(request?.kind ?? '');
    const kindMatches = definition.kinds?.includes(requestKind) ?? requestKind === definition.kind;
    if (!kindMatches) return false;
    return definition.values.length === 0 || definition.values.some((value) => requestMatches(value, request));
  }).sort((left, right) => matchRank(left, definition.values) - matchRank(right, definition.values));
  if (candidates.length === 0) {
    return Object.freeze({ status: 'notRegistered', applicable: true, candidates: 0 });
  }
  try {
    const result = await probeReachableResource({
      requests: candidates.map((request) => ({ ...request, kind: 'candidate' })),
      fetch,
      expectedKind: 'candidate',
      expectedContentType: definition.mime,
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
  if (response.body === null) return 0;
  const reader = response.body.getReader();
  try {
    const first = await reader.read();
    return first.done ? 0 : first.value.byteLength;
  } finally {
    await reader.cancel().catch(() => {});
  }
}
