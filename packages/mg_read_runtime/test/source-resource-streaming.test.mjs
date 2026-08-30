import assert from "node:assert/strict";
import { createServer } from "node:http";
import test from "node:test";

import { serveSourceResource } from "../dist/loopback-resources.js";

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
