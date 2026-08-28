import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

const encode = (prefix, path) => `${prefix}:${Buffer.from(path, 'utf8').toString('base64url')}`;

test('public target chapter yields a nonempty proxy-only page manifest', { timeout: 30_000 }, async () => {
  let proxied;
  await plugin.activate({ dataDir: '.', cacheDir: '.', app: {}, plugin: {}, log: { debug(){}, info(){}, warn(){}, error(){} }, resource: { proxy(request) { proxied = request; return 'http://127.0.0.1/resource/public'; } }, http: { fetch: globalThis.fetch } });
  const content = await plugin.getContent({ id: encode('comic', '/index.php/comic/meinuzishangshideyejianzhenliaoshi'), chapterId: encode('chapter', '/index.php/chapter/101382') });
  assert.equal(content.text, null); assert.ok(content.pages.length > 0); assert.ok(content.pages.every((page) => page.url === 'http://127.0.0.1/resource/public'));
  const image = await plugin.resource(proxied); assert.equal(image.status, 200); assert.ok(image.body.byteLength > 0);
});
