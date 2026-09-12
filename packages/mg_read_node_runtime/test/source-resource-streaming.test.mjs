import assert from "node:assert/strict";
import { createCipheriv } from "node:crypto";
import { createServer } from "node:http";
import test from "node:test";

import { serveSourceResource } from "../dist/loopback-resources.js";
import { openSourceProxyResource } from "../dist/source-resource-proxy.js";

const bmiKey = Buffer.from("aaaaaaaaaaaaaaaa", "ascii");
const bmiIv = Buffer.from("0123456789aaaaaa", "ascii");

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
