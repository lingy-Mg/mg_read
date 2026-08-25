/** Runtime Debug inspector listener contract tests. */
import assert from "node:assert/strict";
import { createServer } from "node:http";
import test from "node:test";

import { RuntimeDebugHttpServer } from "../dist/debug-http.js";
import { DesktopRuntime } from "../dist/desktop-runtime.js";

async function startImageServer() {
  const server = createServer((_request, response) => {
    response.writeHead(200, { "Content-Length": "4", "Content-Type": "image/png" });
    response.end(Buffer.from([137, 80, 78, 71]));
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.once("listening", resolve);
    server.listen({ host: "127.0.0.1", port: 0 });
  });
  const address = server.address();
  assert.ok(address && typeof address !== "string");
  return { server, url: `http://127.0.0.1:${address.port}/cover` };
}

test("Debug inspector is transient, isolates control routes, and redacts cover tokens", async (t) => {
  const image = await startImageServer();
  const inspector = new RuntimeDebugHttpServer({
    discover: async () => ({
      document: {
        components: [{ children: [{ content: { author: "发现作者", coverUrl: image.url, id: "novel:discover", title: "发现书" }, kind: "content" }], kind: "section", title: "推荐" }],
        kind: "document",
      },
      kind: "document",
    }),
    plugins: async () => [],
    search: async () => ({
      items: [{ author: "作者", coverUrl: image.url + "/secret-token-123456", id: "novel:1", title: "测试书" }],
      nextCursor: null,
      totalCount: 1,
    }),
    status: async () => ({ nodeVersion: "24.16.0", runtimeVersion: "test", status: "ready" }),
  });
  t.after(async () => {
    await inspector.dispose();
    await new Promise((resolve) => image.server.close(resolve));
  });

  assert.equal(inspector.status().enabled, false);
  const enabled = await inspector.setEnabled(true);
  assert.equal(enabled.enabled, true);
  const base = enabled.endpoints.find((value) => value.startsWith("http://127.0.0.1:"));
  assert.ok(base);

  const page = await fetch(base);
  assert.equal(page.status, 200);
  assert.match(await page.text(), /MgRead Runtime Debug/);
  assert.equal((await fetch(new URL("/v1/rpc", base))).status, 404);

  const search = await fetch(new URL("/__debug/api/search?pluginId=org.example.test&q=test&pageSize=1", base));
  assert.equal(search.status, 200);
  const result = await search.json();
  const cover = result.result.items[0].cover;
  assert.equal(cover.type, "ordinary-url");
  assert.match(cover.displayUrl, /sec…456/);
  assert.doesNotMatch(JSON.stringify(result), /secret-token-123456/);

  const discover = await fetch(new URL("/__debug/api/discover?pluginId=org.example.test&pageSize=1", base));
  assert.equal(discover.status, 200);
  const discoveryResult = await discover.json();
  assert.equal(discoveryResult.result.document.components[0].kind, "section");
  assert.equal(discoveryResult.result.document.components[0].children[0].content.cover.type, "ordinary-url");

  const probe = await fetch(new URL(`/__debug/api/resource-probe?probeId=${cover.probeId}`, base));
  assert.equal(probe.status, 200);
  assert.equal(probe.headers.get("content-type"), "image/png");
  assert.deepEqual([...new Uint8Array(await probe.arrayBuffer())], [137, 80, 78, 71]);

  const disabled = await inspector.setEnabled(false);
  assert.deepEqual(disabled, { enabled: false, endpoints: [], startedAt: null });
});

test("Runtime rejects Debug listener control without the platform Debug build gate", async (t) => {
  const runtime = new DesktopRuntime();
  t.after(() => runtime.stop());
  await runtime.start();

  const result = await runtime.invokeEmbedded("runtime.debugHttp.setEnabled.v1", { enabled: true });
  assert.equal(result.ok, false);
  assert.equal(result.error.code, "method_not_found");
});
