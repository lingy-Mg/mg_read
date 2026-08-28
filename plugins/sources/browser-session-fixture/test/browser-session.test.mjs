import assert from 'node:assert/strict';
import test from 'node:test';

test('fixture exposes the Android browser-session entry point', async () => {
  const module = await import('../dist/index.mjs');
  let request;
  await module.activate({
    browser: { sessionV1: { request: async value => { request = value; return { status: 200, body: 'Example Domain', verificationState: 'not-required' }; } } },
  });
  const result = await module.search({ query: 'android-webview' });
  assert.equal(result.items[0].title, 'webview:200:not-required');
  assert.equal(request.transport, 'webview');
  assert.equal(request.headers.cookie, undefined);
  assert.equal(request.headers['user-agent'], undefined);
});

test('fixture exposes the rendered HTML transport', async () => {
  let request;
  const module = await import('../dist/index.mjs');
  await module.activate({
    browser: { sessionV1: { request: async value => { request = value; return { status: 200, body: '<html>Example Domain</html>', verificationState: 'not-required' }; } } },
  });
  const result = await module.search({ query: 'android-html' });
  assert.equal(result.items[0].title, 'html:200:not-required');
  assert.equal(request.transport, 'html');
  assert.equal(request.presentation, 'hidden');
});
