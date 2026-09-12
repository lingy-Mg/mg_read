/**
 * 数据源测试临时宿主。
 *
 * 职责：创建绝对临时目录、公共 Context、资源请求记录和有界日志；cleanup 只删除自身 mkdtemp 根目录。
 */
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Buffer } from 'node:buffer';

import { SourceTestFailure, failureFromCause } from './diagnostics.js';
import { createRuntimeLikeFetch, defaultSourceTestUserAgent } from './http.js';

const maximumLogEvents = 64;

export async function createSourceTestHarness({
  plugin,
  pluginId,
  version,
  fetch: sourceFetch = globalThis.fetch,
  prefix = 'mgread-source-test-',
  runtimeVersion = 'source-testkit',
  resourceProxy,
}) {
  if (typeof plugin?.activate !== 'function') {
    throw new SourceTestFailure('source_activate_missing', 'activate', {});
  }
  if (typeof sourceFetch !== 'function') {
    throw new SourceTestFailure('source_fetch_missing', 'activate', {});
  }
  if (!/^[a-z0-9-]{1,48}$/u.test(prefix)) {
    throw new SourceTestFailure('source_temp_prefix_invalid', 'activate', {});
  }

  const root = await mkdtemp(join(tmpdir(), prefix));
  const resourceRequests = [];
  const logEvents = [];
  const runtimeFetch = createRuntimeLikeFetch(sourceFetch);
  const webview = createTestWebView(runtimeFetch);
  const browserSessionRequest = createTestBrowserSession(runtimeFetch);
  let cleaned = false;
  const recordLog = (level, event) => {
    if (logEvents.length >= maximumLogEvents) return;
    logEvents.push(Object.freeze({ level, event: String(event).slice(0, 120) }));
  };
  const context = Object.freeze({
    dataDir: join(root, 'data'),
    cacheDir: join(root, 'cache'),
    http: Object.freeze({ fetch: runtimeFetch }),
    browser: Object.freeze({
      sessionV1: Object.freeze({ request: browserSessionRequest }),
    }),
    webview,
    resource: Object.freeze({
      proxy(request) {
        const captured = freezeResourceRequest(request);
        resourceRequests.push(captured);
        const projected = resourceProxy?.(captured, resourceRequests.length)
          ?? `http://127.0.0.1:1234/v1/source-resource/test-${resourceRequests.length}`;
        if (typeof projected !== 'string' || projected.length === 0) {
          throw new SourceTestFailure(
            'source_resource_projection_invalid',
            'resource.proxy',
            {},
          );
        }
        // Keep the Runtime-facing URL so the CLI can associate a returned
        // cover/page/media URL with the exact upstream descriptor that was
        // registered by the source. This is test metadata, not a plugin API.
        resourceRequests[resourceRequests.length - 1] = Object.freeze({
          ...captured,
          projectedUrl: projected,
        });
        return projected;
      },
    }),
    errors: Object.freeze({
      raise(errorOrCode) {
        const error = typeof errorOrCode === 'string'
          ? { code: errorOrCode, message: defaultPublicErrorMessage(errorOrCode) }
          : errorOrCode;
        const message = typeof error?.message === 'string' ? error.message : 'Plugin public error.';
        const annotation = typeof error?.annotation === 'string' ? error.annotation.trim() : '';
        const thrown = new Error(message);
        thrown.name = 'PluginManagerError';
        thrown.code = typeof error?.code === 'string' ? error.code : 'invalid_request';
        thrown.detail = annotation.length === 0 ? message : `${message}\n注释：${annotation}`;
        throw thrown;
      },
    }),
    log: Object.freeze({
      debug: (event) => recordLog('debug', event),
      info: (event) => recordLog('info', event),
      warn: (event) => recordLog('warn', event),
      error: (event) => recordLog('error', event),
    }),
    app: Object.freeze({
      runtimeVersion,
      nodeVersion: process.versions.node,
      pluginApi: 1,
    }),
    plugin: Object.freeze({ id: pluginId, version }),
  });
  const cleanup = async () => {
    if (cleaned) return;
    cleaned = true;
    await rm(root, { force: true, recursive: true });
  };

  try {
    await plugin.activate(context);
  } catch (error) {
    await cleanup();
    throw failureFromCause('source_activate_failed', 'activate', error);
  }

  return Object.freeze({
    root,
    context,
    resourceRequests,
    logEvents,
    cleanup,
    summary() {
      return Object.freeze({ resources: resourceRequests.length, logs: logEvents.length });
    },
  });
}

function defaultPublicErrorMessage(code) {
  if (code === 'source_access_blocked') return '访问异常，请稍后再试。';
  if (code === 'source_media_resolution_failed') return 'The source could not resolve an external media address.';
  return 'Plugin public error.';
}

function createTestBrowserSession(runtimeFetch) {
  const sessions = new Map();
  return async (request) => {
    const input = request !== null && typeof request === 'object' ? request : {};
    const sessionKey = typeof input.sessionKey === 'string' && input.sessionKey !== '' ? input.sessionKey : 'default';
    const headers = new Headers(input.headers);
    const cookies = sessions.get(sessionKey);
    if (cookies !== undefined && cookies.size > 0 && !headers.has('cookie')) {
      headers.set('cookie', [...cookies].map(([name, value]) => `${name}=${value}`).join('; '));
    }
    const response = await runtimeFetch(input.url, {
      method: input.method === 'POST' ? 'POST' : 'GET',
      headers,
      body: typeof input.body === 'string' ? input.body : undefined,
    });
    rememberCookies(sessions, sessionKey, response.headers);
    const body = await response.text();
    const maximumBytes = Number(input.maxResponseBytes);
    if (Number.isFinite(maximumBytes) && Buffer.byteLength(body) > maximumBytes) {
      throw new SourceTestFailure('source_browser_response_too_large', 'browser.sessionV1', {});
    }
    return Object.freeze({
      version: 1,
      status: response.status,
      body,
      headers: Object.freeze(Object.fromEntries(response.headers)),
      finalUrl: response.url,
      sessionUserAgent: headers.get('user-agent') ?? defaultSourceTestUserAgent,
    });
  };
}

function rememberCookies(sessions, sessionKey, headers) {
  const values = typeof headers.getSetCookie === 'function'
    ? headers.getSetCookie()
    : (headers.get('set-cookie') ?? '').split(/,(?=[^;,=\s]+=[^;,]*)/u).filter(Boolean);
  if (values.length === 0) return;
  const cookies = sessions.get(sessionKey) ?? new Map();
  for (const value of values) {
    const pair = String(value).split(';', 1)[0];
    const separator = pair.indexOf('=');
    if (separator <= 0) continue;
    cookies.set(pair.slice(0, separator).trim(), pair.slice(separator + 1).trim());
  }
  sessions.set(sessionKey, cookies);
}

function freezeResourceRequest(request) {
  const input = request !== null && typeof request === 'object' ? request : {};
  return Object.freeze({
    ...input,
    ...(input.headers === undefined
      ? {}
      : { headers: Object.freeze(Object.fromEntries(new Headers(input.headers))) }),
  });
}

function createTestWebView(runtimeFetch) {
  let currentHtml = '';
  let currentUrl = 'about:blank';
  const page = Object.freeze({
    async navigate(url) {
      const response = await runtimeFetch(url);
      currentUrl = response.url;
      currentHtml = await response.text();
    },
    async getHtml() {
      return currentHtml;
    },
    async fetch(request) {
      const response = await runtimeFetch(request.url, {
        method: request.method,
        headers: request.headers,
        body: request.body ?? undefined,
      });
      const body = request.responseType === 'base64'
        ? Buffer.from(await response.arrayBuffer()).toString('base64')
        : request.responseType === 'json'
          ? await response.json()
          : await response.text();
      return Object.freeze({
        status: response.status,
        url: response.url,
        headers: Object.freeze(Object.fromEntries(response.headers)),
        body,
      });
    },
    async executeJavaScript(script) {
      if (typeof script === 'string' && /Array\.from\(document\.querySelectorAll\(['"]img, div\[data-bmi-manifest\]\[data-src\]['"]\)\)/u.test(script)
        && /currentSrc\|\|i\.src\|\|i\.dataset\.src\|\|i\.dataset\.original/u.test(script)) {
        return extractImageSources(currentHtml);
      }
      throw new SourceTestFailure('source_webview_script_unsupported', 'webview.evaluate', {});
    },
    async click() {
      throw new SourceTestFailure('source_webview_interaction_required', 'webview.click', {});
    },
    async waitForText() {
      throw new SourceTestFailure('source_webview_wait_unsupported', 'webview.waitText', {});
    },
    async getUrl() {
      return currentUrl;
    },
    async show() {
      throw new SourceTestFailure('source_webview_interaction_required', 'webview.show', {});
    },
    async hide() {},
    async close() {},
  });
  return Object.freeze({
    async open() {
      return page;
    },
  });
}

function extractImageSources(html) {
  const values = [];
  for (const match of html.matchAll(/<(?:img\b[^>]*|div\b[^>]*data-bmi-manifest[^>]*)>/giu)) {
    const tag = match[0];
    const attributes = new Map();
    for (const attribute of tag.matchAll(/([:\w-]+)\s*=\s*(["'])(.*?)\2/giu)) {
      attributes.set(attribute[1].toLowerCase(), decodeHtmlEntities(attribute[3]));
    }
    const value = attributes.get('src') ?? attributes.get('data-src') ?? attributes.get('data-original') ?? '';
    if (value !== '' && !value.startsWith('/static/') && !value.startsWith('https://www.comicbox.xyz/static/')) values.push(value);
  }
  return values;
}

function decodeHtmlEntities(value) {
  return value.replaceAll('&amp;', '&').replaceAll('&quot;', '"').replaceAll('&#39;', "'");
}
