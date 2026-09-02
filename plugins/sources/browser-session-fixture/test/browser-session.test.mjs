import assert from 'node:assert/strict';
import test from 'node:test';

import { buildPluginArtifact } from '../tools/mgread.mjs';

test('fixture exposes the Android browser-session entry point', async () => {
  const module = await import('../dist/index.mjs');
  let request;
  await module.activate({
    browser: { sessionV1: { request: async value => { request = value; return { status: 200, body: 'Example Domain' }; } } },
  });
  const result = await module.search({ query: 'android-webview' });
  assert.equal(result.items[0].title, 'webview:200');
  assert.equal(request.transport, 'webview');
  assert.equal(request.headers.cookie, undefined);
  assert.equal(request.headers['user-agent'], undefined);
});

test('fixture exposes the rendered HTML transport', async () => {
  let request;
  const module = await import('../dist/index.mjs');
  await module.activate({
    browser: { sessionV1: { request: async value => { request = value; return { status: 200, body: '<html>Example Domain</html>' }; } } },
  });
  const result = await module.search({ query: 'android-html' });
  assert.equal(result.items[0].title, 'html:200');
  assert.equal(request.transport, 'html');
  assert.equal(request.presentation, 'hidden');
});

test('fixture exposes the canonical Runtime transfer builder', async () => {
  const artifact = await buildPluginArtifact({ versionOverride: '0.1.1-devsync.1.fixture' });
  assert.equal(artifact.format, 'singleFile');
  assert.match(artifact.fileName, /\.mgplugin\.js$/u);
  assert.ok(artifact.bytes.length > 0);
});
