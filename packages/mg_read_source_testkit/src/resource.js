/**
 * Runtime-owned 资源描述的有界 live 探测。
 *
 * 职责：最多检查少量候选，记录状态/MIME，并只读取首个健康响应块后立即取消。
 */
import { SourceTestFailure, causeSummary } from './diagnostics.js';
import { createRuntimeLikeFetch } from './http.js';

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
      const response = await runtimeFetch(request.url, {
        headers: request.headers,
        redirect: 'follow',
      });
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
