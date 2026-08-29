/** Contract tests for the single-page ctx.webview boundary. */
import assert from "node:assert/strict";
import test from "node:test";

import { createPluginWebViewApi } from "../dist/plugin-webview-page.js";

function fixture(respond) {
  const calls = [];
  const api = createPluginWebViewApi({
    pluginId: "org.mgread.fixture",
    pluginName: "Fixture Source",
    provider: {
      async request(value) {
        calls.push(value);
        return respond(value);
      },
    },
    withScope: operation => operation({
      signal: new AbortController().signal,
      deadlineUnixMs: String(Date.now() + 60_000),
    }),
  });
  return { api, calls };
}

test("open reuses one handle and sends no session key", async () => {
  const { api, calls } = fixture(() => ({}));
  const first = await api.open({ visible: true });
  const second = await api.open();
  assert.equal(first, second);
  assert.deepEqual(calls.map(call => ({ operation: call.operation, visible: call.visible })), [
    { operation: "page.open", visible: true },
    { operation: "page.open", visible: false },
  ]);
  assert.equal(calls[0].pluginId, "org.mgread.fixture");
  assert.equal(calls[0].pluginName, "Fixture Source");
  assert.equal("sessionKey" in calls[0], false);
});

test("ordinary page operations run FIFO while controls bypass the queue", async () => {
  let markStarted;
  let releaseFirst;
  const started = new Promise(resolve => { markStarted = resolve; });
  const blocked = new Promise(resolve => { releaseFirst = resolve; });
  const { api, calls } = fixture(request => {
    if (request.operation === "page.navigate" && request.url.endsWith("/first")) {
      markStarted();
      return blocked;
    }
    return {};
  });
  const page = await api.open();
  calls.length = 0;

  const first = page.navigate("https://example.com/first");
  await started;
  const second = page.navigate("https://example.com/second");
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(calls.map(call => call.operation), ["page.navigate"]);

  await page.hide();
  assert.deepEqual(calls.map(call => call.operation), ["page.navigate", "page.hide"]);
  releaseFirst({});
  await Promise.all([first, second]);
  assert.deepEqual(calls.map(call => `${call.operation}:${call.url ?? ""}`), [
    "page.navigate:https://example.com/first",
    "page.hide:",
    "page.navigate:https://example.com/second",
  ]);
});

test("page forwards all operations and arbitrary JSON values", async () => {
  const values = [null, true, 42, "text", [1, "two"], { nested: { ok: true } }];
  let index = 0;
  const { api, calls } = fixture(request => {
    switch (request.operation) {
      case "page.evaluate": return { value: values[index++] };
      case "page.html": return { html: "<html><body>live</body></html>" };
      case "page.fetch": return { status: 200, url: request.url, headers: { "content-type": "application/json" }, body: { ok: true } };
      case "page.waitText": return { url: "https://example.com/done" };
      case "page.getUrl": return { url: "https://example.com/current" };
      default: return {};
    }
  });
  const page = await api.open({ visible: true });
  for (const expected of values) {
    assert.deepEqual(await page.executeJavaScript("await Promise.resolve(); return 1;"), expected);
  }
  await page.navigate("https://example.com/start");
  assert.match(await page.getHtml(), /live/);
  assert.deepEqual(await page.fetch({ url: "https://api.example.com/data", responseType: "json" }), {
    status: 200,
    url: "https://api.example.com/data",
    headers: { "content-type": "application/json" },
    body: { ok: true },
  });
  await page.click({ x: 20, y: 40 });
  await page.inputText("hello");
  await page.key({ key: "Enter", modifiers: ["control"] });
  assert.equal((await page.waitForText({ text: "ready", scope: "text", timeoutMs: 5_000 })).url, "https://example.com/done");
  assert.equal(await page.getUrl(), "https://example.com/current");
  await page.hide();
  await page.show();
  await page.close();
  assert.deepEqual(calls.slice(7).map(call => call.operation), [
    "page.navigate", "page.html", "page.fetch", "page.click", "page.input",
    "page.key", "page.waitText", "page.getUrl", "page.hide", "page.show",
    "page.close",
  ]);
  assert.equal(calls.at(-1).operation, "page.close");
});

test("page rejects invalid requests and non-JSON script results", async () => {
  const { api } = fixture(request => request.operation === "page.evaluate" ? { value: Number.NaN } : {});
  const page = await api.open();
  await assert.rejects(page.executeJavaScript("return NaN;"), error => error?.code === "plugin_invalid_response");
  await assert.rejects(async () => page.navigate("file:///secret"), error => error?.code === "invalid_request");
  await assert.rejects(async () => page.click({ x: -1, y: 0 }), error => error?.code === "invalid_request");
  await assert.rejects(async () => page.waitForText({ text: "ready", timeoutMs: 0 }), error => error?.code === "invalid_request");
});

test("Android return-value error envelopes reject every page operation with the stable code", async () => {
  let response = {};
  const { api } = fixture(() => response);
  const page = await api.open();
  const operations = [
    ["open", () => api.open({ visible: true })],
    ["navigate", () => page.navigate("https://example.com/")],
    ["executeJavaScript", () => page.executeJavaScript("return true;")],
    ["getHtml", () => page.getHtml()],
    ["fetch", () => page.fetch({ url: "https://example.com/data" })],
    ["click", () => page.click({ x: 1, y: 1 })],
    ["inputText", () => page.inputText("text")],
    ["key", () => page.key({ key: "Enter" })],
    ["waitForText", () => page.waitForText({ text: "ready", timeoutMs: 1_000 })],
    ["getUrl", () => page.getUrl()],
    ["show", () => page.show()],
    ["hide", () => page.hide()],
    ["close", () => page.close()],
  ];
  const codes = [
    "cancelled",
    "interaction_required",
    "overloaded",
    "plugin_execution_failed",
    "timeout",
    "unsupported",
  ];

  for (const code of codes) {
    response = { __mgreadBrowserSessionError: code };
    for (const [name, operation] of operations) {
      await assert.rejects(operation, error => {
        assert.equal(error?.code, code, `${name} must preserve ${code}`);
        return true;
      });
    }
  }
});
