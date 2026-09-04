/**
 * Optional live smoke. Set MGREAD_CHROME_PATH to an isolated Chromium executable.
 * The adapter exercises only the public WebView surface used by the plugin.
 */
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

const chromePath = process.env.MGREAD_CHROME_PATH;

test('live isolated browser reaches one Ncat video and its HLS playlist', { timeout: 120_000, skip: !chromePath }, async () => {
  const browser = await openBrowser(chromePath);
  const resources = [];
  try {
    await plugin.activate({
      dataDir: '.live-data', cacheDir: '.live-cache',
      app: { runtimeVersion: 'live', nodeVersion: process.versions.node, pluginApi: 1 },
      plugin: { id: 'org.mgread.ncat-video', version: '1.0.0' },
      log: { debug() {}, info() {}, warn() {}, error() {} },
      webview: { async open() { return browser.page; } },
      resource: { proxy(request) { resources.push(request); return 'http://127.0.0.1/live-resource'; } },
      http: { fetch },
    });
    const discovery = await plugin.discover({ target: 'category:movie', cursor: null, collectionId: null, pageSize: 3 });
    const item = discovery.document.components[0].children[0].items[0]?.content;
    assert.ok(item);
    const detail = await plugin.getDetail({ id: item.id });
    const chapters = await plugin.getChapters({ id: detail.id });
    assert.ok(chapters.items.length > 0);
    const content = await plugin.getContent({ id: detail.id, chapterId: chapters.items[0].id });
    assert.equal(content.media.resourceType, 'hls');
    const media = resources.at(-1);
    const response = await retryFetch(media.url, media.headers);
    const reader = response.body.getReader();
    const first = await reader.read();
    await reader.cancel();
    assert.equal(response.ok, true);
    assert.match(Buffer.from(first.value ?? []).toString('utf8'), /^#EXTM3U/mu);
  } finally {
    await browser.close();
  }
});

async function openBrowser(executable) {
  const profile = await mkdtemp(join(tmpdir(), 'mgread-ncat-live-'));
  const port = 10_000 + Math.floor(Math.random() * 40_000);
  const child = spawn(executable, [
    '--headless=new', '--no-first-run', '--disable-sync', '--disable-extensions', '--mute-audio',
    '--autoplay-policy=no-user-gesture-required', '--use-mock-keychain', '--password-store=basic',
    `--user-data-dir=${profile}`, `--remote-debugging-port=${port}`, 'about:blank',
  ], { stdio: 'ignore' });
  let target;
  for (let attempt = 0; attempt < 40; attempt += 1) {
    try {
      const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
      target = targets.find((value) => value.type === 'page' && value.url === 'about:blank');
      if (target) break;
    } catch { /* wait for Chromium */ }
    await delay(250);
  }
  if (!target) throw new Error('Chromium CDP target was not created.');
  const socket = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
  let commandId = 0;
  const pending = new Map();
  socket.onmessage = (event) => {
    const message = JSON.parse(event.data);
    const callbacks = pending.get(message.id);
    if (!callbacks) return;
    pending.delete(message.id);
    if (message.error) callbacks.reject(new Error(message.error.message));
    else callbacks.resolve(message.result);
  };
  const send = (method, params = {}) => new Promise((resolve, reject) => {
    const id = ++commandId;
    pending.set(id, { resolve, reject });
    socket.send(JSON.stringify({ id, method, params }));
  });
  await send('Page.enable');
  const page = {
    async navigate(url) { await send('Page.navigate', { url }); await delay(6_000); },
    async executeJavaScript(code) {
      const result = await send('Runtime.evaluate', { expression: code, returnByValue: true, awaitPromise: true });
      if (result.exceptionDetails) throw new Error(result.exceptionDetails.text || 'Browser evaluation failed.');
      return result.result.value;
    },
  };
  return {
    page,
    async close() {
      socket.close();
      child.kill('SIGTERM');
      await delay(400);
      await rm(profile, { recursive: true, force: true });
    },
  };
}

function delay(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }

async function retryFetch(url, headers) {
  let lastError;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    try { return await fetch(url, { headers, signal: AbortSignal.timeout(20_000) }); }
    catch (error) { lastError = error; await delay(250 * (attempt + 1)); }
  }
  throw lastError;
}
