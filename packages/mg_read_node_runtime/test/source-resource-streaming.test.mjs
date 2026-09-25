import assert from "node:assert/strict";
import { createCipheriv } from "node:crypto";
import { createServer } from "node:http";
import test from "node:test";

import { serveSourceResource } from "../dist/loopback-resources.js";
import { openSourceProxyResource } from "../dist/source-resource-proxy.js";
import { SourceResourceCoordinator } from "../dist/source-resource-coordinator.js";
import { encodeSourceResourceToken } from "../dist/source-resource-token.js";

const bmiKey = Buffer.from("aaaaaaaaaaaaaaaa", "ascii");
const bmiIv = Buffer.from("0123456789aaaaaa", "ascii");
const prefixedIvKey = Buffer.from("0123456789abcdef0123456789abcdef", "ascii");

test("source image proxy forwards a bounded handler descriptor to the owning plugin", async () => {
  let calls = 0;
  const coordinator = new SourceResourceCoordinator({ fetch() { throw new Error("unexpected upstream fetch"); } },
    () => {}, () => false, async (pluginId, request) => {
      calls += 1;
      assert.equal(pluginId, "org.mgread.jmcomic");
      assert.equal(request.handler, "jm-stripes-v1");
      assert.deepEqual(request.params, { segments: 2 });
      return new Response(Uint8Array.from([137, 80, 78, 71]), { headers: { "content-type": "image/png" } });
    });
  const request = { kind: "image", url: "https://images.example/photo.png", handler: "jm-stripes-v1", params: { segments: 2 } };
  const token = encodeSourceResourceToken("org.mgread.jmcomic", request);
  const resource = await coordinator.open(token, {}, new AbortController().signal, () => "unused");
  assert.equal(calls, 1);
  assert.equal(resource.response.headers.get("content-type"), "image/png");
  assert.deepEqual([...new Uint8Array(await resource.response.arrayBuffer())], [137, 80, 78, 71]);
  const invalid = await coordinator.open(encodeSourceResourceToken("org.mgread.jmcomic", { ...request, kind: "hls" }),
    {}, new AbortController().signal, () => "unused");
  assert.equal(invalid, undefined);
  assert.equal(calls, 1);
});

test("source resources deliver the first chunk before the upstream body completes", async (t) => {
  const releaseTail = Promise.withResolvers();
  const finished = Promise.withResolvers();
  let upstreamCompleted = false;
  const pluginManager = {
    async openSourceResource(_token, _headers, signal) {
      return {
        request: { kind: "image", url: "https://images.example/page.webp" },
        proxy() { throw new Error("not used"); },
        response: new Response(new ReadableStream({
          start(controller) {
            controller.enqueue(Uint8Array.from([1, 2, 3]));
            releaseTail.promise.then(() => {
              if (!signal.aborted) controller.enqueue(Uint8Array.from([4, 5, 6]));
              controller.close();
              upstreamCompleted = true;
            });
          },
        }), { headers: { "content-type": "image/webp" } }),
      };
    },
  };
  const server = createServer((request, response) => {
    void serveSourceResource(pluginManager, "token", response, (status, bytes) => {
      finished.resolve({ status, bytes });
    }, request);
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  t.after(() => new Promise((resolve) => server.close(resolve)));
  const address = server.address();
  assert.notEqual(address, null);
  assert.equal(typeof address, "object");

  const response = await fetch(`http://127.0.0.1:${address.port}/v1/source-resource/token`);
  assert.equal(response.headers.get("content-type"), "image/webp");
  const reader = response.body.getReader();
  const first = await reader.read();
  assert.deepEqual([...first.value], [1, 2, 3]);
  assert.equal(upstreamCompleted, false);
  releaseTail.resolve();
  const tail = await reader.read();
  assert.deepEqual([...tail.value], [4, 5, 6]);
  assert.equal((await reader.read()).done, true);
  assert.deepEqual(await finished.promise, { status: 200, bytes: 6 });
});

test("source resource proxy corrects a declared image MIME from the existing response stream", async () => {
  const url = "https://images.example/cover.png";
  let fetches = 0;
  let tailPulls = 0;
  const first = Uint8Array.from([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]);
  const resource = await openSourceProxyResource({
    request: {
      kind: "image",
      url,
      resourceTransform: "sniff-image-content-type-v1",
      headers: {},
    },
    async fetch() {
      fetches += 1;
      return new Response(new ReadableStream({
        start(controller) { controller.enqueue(first); },
        pull(controller) {
          tailPulls += 1;
          controller.enqueue(Uint8Array.from([1, 2, 3]));
          controller.close();
        },
      }, { highWaterMark: 0 }), { headers: { "content-type": "image/png" } });
    },
    proxy() { return "unused"; },
  }, {}, new AbortController().signal);
  assert.notEqual(resource, undefined);
  assert.equal(fetches, 1);
  assert.equal(tailPulls, 0);
  assert.equal(resource.response.headers.get("content-type"), "image/gif");
  assert.deepEqual(
    [...new Uint8Array(await resource.response.arrayBuffer())],
    [...first, 1, 2, 3],
  );
  assert.equal(tailPulls, 1);
});

test("source resource proxy decodes AES-CBC split images in the Node data plane", async () => {
  const firstUrl = "https://images.example/page.b_0";
  const secondUrl = "https://images.example/page.b_1";
  const firstPlain = Buffer.from([0, 0, 0, 1, 0, 0, 0, 1, 74, 70, 73, 70, 0, 1, 2]);
  const secondPlain = Buffer.from([3, 4, 5, 6]);
  const encrypt = (plain) => {
    const cipher = createCipheriv("aes-128-cbc", bmiKey, bmiIv);
    return Buffer.concat([cipher.update(plain), cipher.final()]);
  };
  const responses = new Map([
    [firstUrl, new Response(encrypt(firstPlain), { status: 200 })],
    [secondUrl, new Response(encrypt(secondPlain), { status: 200 })],
  ]);
  const resource = await openSourceProxyResource({
    request: {
      kind: "image",
      url: firstUrl,
      urls: [firstUrl, secondUrl],
      resourceTransform: "aes-cbc-split-image-v1",
      headers: { Referer: "https://comicbox.example/" },
    },
    fetch: async (url) => responses.get(String(url)),
    proxy() { return "unused"; },
  }, {}, new AbortController().signal);
  assert.notEqual(resource, undefined);
  assert.equal(resource.response.status, 200);
  assert.equal(resource.response.headers.get("content-type"), "image/jpeg");
  assert.deepEqual(
    [...new Uint8Array(await resource.response.arrayBuffer())],
    [255, 216, 255, 224, 0, 16, 74, 70, 73, 70, 0, 1, 0, 1, 2, 3, 4, 5, 6],
  );
});

test("source resource proxy decodes AES-256-CBC images with a prefixed IV", async () => {
  const url = "https://images.example/encrypted.jpg";
  const iv = Buffer.from("abcdefghijklmnop", "ascii");
  const plain = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 1, 2, 3]);
  const cipher = createCipheriv("aes-256-cbc", prefixedIvKey, iv);
  const encrypted = Buffer.concat([iv, cipher.update(plain), cipher.final()]);
  const resource = await openSourceProxyResource({
    request: {
      kind: "image",
      url,
      resourceTransform: "aes-cbc-prefixed-iv-image-v1",
      resourceTransformKey: prefixedIvKey.toString("ascii"),
      headers: { Referer: "https://comic.example/" },
    },
    fetch: async () => new Response(encrypted, { status: 200, headers: { "content-type": "image/jpeg" } }),
    proxy() { return "unused"; },
  }, {}, new AbortController().signal);
  assert.notEqual(resource, undefined);
  assert.equal(resource.response.headers.get("content-type"), "image/jpeg");
  assert.deepEqual(Buffer.from(await resource.response.arrayBuffer()), plain);
});

test("source resource proxy joins encrypt-then-split AES-CBC images before decrypting", async () => {
  const firstUrl = "https://images.example/manifest-part-0";
  const secondUrl = "https://images.example/manifest-part-1";
  const plain = Buffer.from([0, 0, 0, 1, 0, 0, 0, 1, 74, 70, 73, 70, 1, 2, 3, 4, 5]);
  const cipher = createCipheriv("aes-128-cbc", bmiKey, bmiIv);
  const encrypted = Buffer.concat([cipher.update(plain), cipher.final()]);
  const splitAt = 13;
  const responses = new Map([
    [firstUrl, new Response(encrypted.subarray(0, splitAt), { status: 200 })],
    [secondUrl, new Response(encrypted.subarray(splitAt), { status: 200 })],
  ]);
  const resource = await openSourceProxyResource({
    request: {
      kind: "image",
      url: firstUrl,
      urls: [firstUrl, secondUrl],
      resourceTransform: "aes-cbc-encrypt-then-split-image-v1",
      headers: {},
    },
    fetch: async (url) => responses.get(String(url)),
    proxy() { return "unused"; },
  }, {}, new AbortController().signal);
  assert.notEqual(resource, undefined);
  assert.equal(resource.response.headers.get("content-type"), "image/jpeg");
  assert.deepEqual(
    [...new Uint8Array(await resource.response.arrayBuffer())],
    [255, 216, 255, 224, 0, 16, 74, 70, 73, 70, 0, 1, 1, 2, 3, 4, 5],
  );
});

test("source resource upstream failures return bad gateway", async (t) => {
  const finished = Promise.withResolvers();
  const pluginManager = {
    async openSourceResource() {
      throw new Error("upstream unavailable");
    },
  };
  const server = createServer((request, response) => {
    void serveSourceResource(
      pluginManager,
      "token",
      response,
      (status) => finished.resolve(status),
      request,
    );
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  t.after(() => new Promise((resolve) => server.close(resolve)));
  const address = server.address();
  assert.notEqual(address, null);
  assert.equal(typeof address, "object");

  const response = await fetch(
    `http://127.0.0.1:${address.port}/v1/source-resource/token`,
  );
  assert.equal(response.status, 502);
  assert.equal(await finished.promise, 502);
});
