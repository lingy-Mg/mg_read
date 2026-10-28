/**
 * Node 测试宿主的公开 HTTP 行为投影。
 *
 * 职责：像正式 Runtime 的 ctx.http.fetch 一样，在来源未声明时补充精简桌面 UA，并让 proxyMode=direct 绕过环境代理。
 * IO：默认请求仍委托 CLI 注入的 fetch；直连请求只使用 Node HTTP(S)，有界跟随重定向，并流式解压正文以匹配正式 fetch。
 */
import { Buffer } from 'node:buffer';
import { request as requestHttp } from 'node:http';
import { request as requestHttps } from 'node:https';
import { Readable, compose } from 'node:stream';
import { createGunzip, createInflate, createBrotliDecompress, createZstdDecompress } from 'node:zlib';

export const defaultSourceTestUserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36';
const maximumRedirects = 10;

export function createRuntimeLikeFetch(sourceFetch, { directFetch = directHttpFetch } = {}) {
  return async (input, init = {}) => {
    const { proxyMode, ...requestInit } = init;
    const headers = new Headers(requestInit.headers);
    if (!headers.has('user-agent')) headers.set('user-agent', defaultSourceTestUserAgent);
    const fetch = proxyMode === 'direct' ? directFetch : sourceFetch;
    return fetch(input, { ...requestInit, headers });
  };
}

async function directHttpFetch(input, init = {}, redirects = 0) {
  const url = new URL(input instanceof Request ? input.url : input);
  if (url.protocol !== 'http:' && url.protocol !== 'https:') throw new TypeError('Direct source request protocol is unsupported.');
  if (input instanceof Request && init.body === undefined && input.body !== null) throw new TypeError('Direct Request bodies are unsupported.');
  const method = String(init.method ?? (input instanceof Request ? input.method : 'GET')).toUpperCase();
  const headers = new Headers(input instanceof Request ? input.headers : undefined);
  for (const [name, value] of new Headers(init.headers)) headers.set(name, value);
  const body = requestBody(init.body);
  if (body !== null && !headers.has('content-length')) headers.set('content-length', String(typeof body === 'string' ? Buffer.byteLength(body) : body.byteLength));
  const transport = url.protocol === 'https:' ? requestHttps : requestHttp;
  return new Promise((resolve, reject) => {
    const request = transport(url, { agent: false, method, headers: Object.fromEntries(headers), signal: init.signal }, (incoming) => {
      const status = incoming.statusCode ?? 0;
      const location = incoming.headers.location;
      if (location !== undefined && isRedirect(status)) {
        if (init.redirect === 'error') { incoming.resume(); reject(new TypeError('Direct source request redirect is disallowed.')); return; }
        if (init.redirect !== 'manual') {
          incoming.resume();
          if (redirects >= maximumRedirects) { reject(new TypeError('Direct source request exceeded the redirect limit.')); return; }
          const switchToGet = status === 303 || ((status === 301 || status === 302) && method === 'POST');
          const nextHeaders = new Headers(headers);
          if (switchToGet) { nextHeaders.delete('content-length'); nextHeaders.delete('content-type'); }
          directHttpFetch(new URL(location, url), { ...init, method: switchToGet ? 'GET' : method, body: switchToGet ? undefined : init.body, headers: nextHeaders }, redirects + 1).then(resolve, reject);
          return;
        }
      }
      const responseHeaders = new Headers();
      for (const [name, value] of Object.entries(incoming.headers)) {
        for (const item of Array.isArray(value) ? value : value === undefined ? [] : [value]) responseHeaders.append(name, item);
      }
      const coding = String(incoming.headers['content-encoding'] ?? '').trim().toLowerCase();
      const decoder = coding === 'gzip' ? createGunzip() : coding === 'deflate' ? createInflate()
        : coding === 'br' ? createBrotliDecompress() : coding === 'zstd' ? createZstdDecompress() : null;
      // compose propagates cancellation/errors to the HTTP response as well as the decoder.
      const body = decoder === null ? incoming : compose(incoming, decoder);
      const response = new Response(Readable.toWeb(body), { status, statusText: incoming.statusMessage, headers: responseHeaders });
      Object.defineProperty(response, 'url', { value: url.toString() });
      resolve(response);
    });
    request.on('error', reject);
    if (body !== null) request.write(body);
    request.end();
  });
}

function requestBody(body) {
  if (body === undefined || body === null) return null;
  if (typeof body === 'string' || body instanceof Uint8Array) return body;
  if (body instanceof ArrayBuffer) return new Uint8Array(body);
  if (body instanceof URLSearchParams) return body.toString();
  throw new TypeError('Direct source request body is unsupported.');
}

function isRedirect(status) {
  return status === 301 || status === 302 || status === 303 || status === 307 || status === 308;
}
