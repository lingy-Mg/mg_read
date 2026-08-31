/**
 * Node 测试宿主的公开 HTTP 行为投影。
 *
 * 职责：像正式 Runtime 的 ctx.http.fetch 一样，在来源未声明时补充精简桌面 UA；不实现 Runtime 私有代理。
 */
export const defaultSourceTestUserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36';

export function createRuntimeLikeFetch(sourceFetch) {
  return async (input, init = {}) => {
    const headers = new Headers(init.headers);
    if (!headers.has('user-agent')) headers.set('user-agent', defaultSourceTestUserAgent);
    return sourceFetch(input, { ...init, headers });
  };
}
