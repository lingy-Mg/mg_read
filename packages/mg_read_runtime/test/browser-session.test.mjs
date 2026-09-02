/** Contract tests for the platform-owned browser.session.v1 boundary. */
import assert from "node:assert/strict";
import test from "node:test";

import {
  requestPluginBrowserInteraction,
  requestPluginBrowserSession,
  requestPluginWebViewDebug,
} from "../dist/plugin-browser-session.js";

function request(overrides = {}) {
  return {
    version: 1,
    sessionKey: "fixture",
    url: "https://example.com/protected",
    method: "GET",
    headers: { accept: "text/html" },
    body: null,
    interaction: "allow",
    presentation: "hidden",
    transport: "webview",
    timeoutMs: 5_000,
    maxResponseBytes: 4_096,
    ...overrides,
  };
}

test("v1 forwards all host transports and both presentation modes", async () => {
  const calls = [];
  const provider = {
    async request(value) {
      calls.push(value);
      return {
        version: 1,
        status: 200,
        finalUrl: value.url,
        headers: { "content-type": "text/html" },
        body: "ok",
        userAgent: "must-not-cross-the-runtime-boundary",
        verificationState: "verified",
      };
    },
  };
  const signal = new AbortController().signal;
  const webview = await requestPluginBrowserSession(
    provider,
    "org.mgread.fixture",
    request(),
    signal,
    String(Date.now() + 10_000),
  );
  const http = await requestPluginBrowserSession(
    provider,
    "org.mgread.fixture",
    request({ presentation: "visible", transport: "http" }),
    signal,
    String(Date.now() + 10_000),
  );
  const html = await requestPluginBrowserSession(
    provider,
    "org.mgread.fixture",
    request({ presentation: "visible", transport: "html" }),
    signal,
    String(Date.now() + 10_000),
  );
  assert.deepEqual(calls.map(({ presentation, transport }) => ({ presentation, transport })), [
    { presentation: "hidden", transport: "webview" },
    { presentation: "visible", transport: "http" },
    { presentation: "visible", transport: "html" },
  ]);
  assert.equal(webview.userAgent, undefined);
  assert.equal(http.userAgent, undefined);
  assert.equal(html.userAgent, undefined);
});

test("v1 rejects omitted mode fields and plugin-owned credentials", async () => {
  const provider = { async request() { throw new Error("unreachable"); } };
  const signal = new AbortController().signal;
  for (const invalid of [
    request({ presentation: undefined }),
    request({ transport: undefined }),
    request({ transport: "unsupported" }),
    request({ headers: { cookie: "forbidden" } }),
    request({ headers: { "user-agent": "forbidden" } }),
  ]) {
    await assert.rejects(
      requestPluginBrowserSession(
        provider,
        "org.mgread.fixture",
        invalid,
        signal,
        String(Date.now() + 10_000),
      ),
      (error) => error?.code === "invalid_request",
    );
  }
});

test("v1 preserves stable browser errors crossing an embedded module realm", async () => {
  const provider = {
    async request() {
      throw {
        name: "PluginBrowserSessionError",
        code: "unsupported",
        message: "The host browser session could not complete the request.",
      };
    },
  };
  await assert.rejects(
    requestPluginBrowserSession(
      provider,
      "org.mgread.fixture",
      request(),
      new AbortController().signal,
      String(Date.now() + 10_000),
    ),
    (error) => error?.code === "unsupported",
  );
});

test("v1 exposes bounded WebView interactions without accepting scripts or global targets", async () => {
  const calls = [];
  const provider = {
    async request(value) {
      calls.push(value);
      return {
        version: 1,
        accepted: true,
        action: value.action,
        ...(value.action === "coordinates" ? { x: 1, y: 2, width: 3, height: 4 } : {}),
      };
    },
  };
  const signal = new AbortController().signal;
  const result = await requestPluginBrowserInteraction(
    provider,
    "org.mgread.fixture",
    {
      version: 1,
      sessionKey: "fixture",
      url: "https://example.com/protected",
      selector: "#control",
      presentation: "hidden",
      timeoutMs: 5_000,
      action: "coordinates",
      script: "document.body.innerHTML='unsafe'",
    },
    signal,
    String(Date.now() + 10_000),
  );
  assert.equal(result.x, 1);
  assert.equal(calls[0].pluginId, "org.mgread.fixture");
  assert.equal(calls[0].operation, "interaction");
  assert.equal(calls[0].selector, "#control");
  assert.equal("script" in calls[0], false);
});

test("source WebView debug control pins and shows only the requested plugin", async () => {
  const calls = [];
  const provider = {
    async request(value) {
      calls.push(value);
      return { version: 1, accepted: true, action: value.action };
    },
  };
  await requestPluginWebViewDebug(
    provider,
    "org.mgread.fixture",
    "Fixture Source",
    "enter",
    new AbortController().signal,
    String(Date.now() + 10_000),
  );
  assert.deepEqual({
    action: calls[0].action,
    operation: calls[0].operation,
    pluginId: calls[0].pluginId,
    pluginName: calls[0].pluginName,
    version: calls[0].version,
  }, {
    action: "enter",
    operation: "debug",
    pluginId: "org.mgread.fixture",
    pluginName: "Fixture Source",
    version: 1,
  });
});
