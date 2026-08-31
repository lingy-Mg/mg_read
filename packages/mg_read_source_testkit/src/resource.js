/**
 * Runtime-owned 资源描述的有界 live 探测。
 *
 * 职责：最多检查少量候选，记录状态/MIME，并只读取首个健康响应块后立即取消。
 */
import { SourceTestFailure, causeSummary } from './diagnostics.js';

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
      const response = await sourceFetch(request.url, {
        headers: request.headers,
        redirect: 'follow',
      });
      const contentType = (response.headers.get('content-type') ?? '').slice(0, 80);
      const attempt = { index: index + 1, status: response.status, contentType };
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
      attempts.push(Object.freeze({ index: index + 1, ...causeSummary(error) }));
    }
  }
  throw new SourceTestFailure('source_resource_unreachable', 'resource', {
    expectedKind,
    attempts: Object.freeze(attempts),
  });
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
