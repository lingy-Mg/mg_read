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
import { createRuntimeLikeFetch } from './http.js';

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
  let cleaned = false;
  const recordLog = (level, event) => {
    if (logEvents.length >= maximumLogEvents) return;
    logEvents.push(Object.freeze({ level, event: String(event).slice(0, 120) }));
  };
  const context = Object.freeze({
    dataDir: join(root, 'data'),
    cacheDir: join(root, 'cache'),
    http: Object.freeze({ fetch: runtimeFetch }),
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
        return projected;
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
    async executeJavaScript() {
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
