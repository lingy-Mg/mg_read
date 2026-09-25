import assert from 'node:assert/strict';
import test from 'node:test';

import { probeReachableResource } from '../index.js';

test('image MIME sniffing reuses one response and keeps signature validation strict', async () => {
  const url = 'https://images.example/cover.png';
  let fetches = 0;
  let tailPulls = 0;
  const first = Uint8Array.from([0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50]);
  const result = await probeReachableResource({
    requests: [{
      kind: 'image',
      url,
      headers: {},
      resourceTransform: 'sniff-image-content-type-v1',
    }],
    async fetch() {
      fetches += 1;
      return new Response(new ReadableStream({
        start(controller) { controller.enqueue(first); },
        pull(controller) {
          tailPulls += 1;
          controller.enqueue(Uint8Array.from([1, 2, 3]));
          controller.close();
        },
      }, { highWaterMark: 0 }), { headers: { 'content-type': 'image/png' } });
    },
    expectedKind: 'image',
    expectedContentType: /^image\/webp$/u,
    validatePrefix(bytes, contentType) {
      return contentType === 'image/webp'
        && Buffer.from(bytes.subarray(0, 4)).toString('ascii') === 'RIFF'
        && Buffer.from(bytes.subarray(8, 12)).toString('ascii') === 'WEBP';
    },
  });

  assert.equal(fetches, 1);
  assert.equal(tailPulls, 0);
  assert.equal(result.contentType, 'image/webp');
  assert.equal(result.bytesRead, first.byteLength);
});

test('source image handler is probed through its decoded response', async () => {
  let invoked = 0;
  const bytes = Uint8Array.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1]);
  const result = await probeReachableResource({
    requests: [{ kind: 'image', url: 'https://images.example/scrambled.webp', handler: 'stripes', params: { segments: 2 } }],
    plugin: { async getResource(request) { invoked += 1; assert.equal(request.params.segments, 2); return { bytes, mimeType: 'image/png' }; } },
    fetch() { throw new Error('direct fetch would bypass image decoding'); },
    validatePrefix(prefix) { return Buffer.from(prefix.subarray(0, 8)).equals(Buffer.from(bytes.subarray(0, 8))); },
  });
  assert.equal(invoked, 1);
  assert.equal(result.contentType, 'image/png');
});
