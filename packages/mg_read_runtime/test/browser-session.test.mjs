/** Contract tests for the platform-owned browser.session.v1 boundary. */
import assert from "node:assert/strict";
import test from "node:test";

import {
  requestPluginBrowserSession,
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

test("v1 forwards both host transports and both presentation modes", async () => {
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
  assert.deepEqual(calls.map(({ presentation, transport }) => ({ presentation, transport })), [
    { presentation: "hidden", transport: "webview" },
    { presentation: "visible", transport: "http" },
  ]);
  assert.equal(webview.userAgent, undefined);
  assert.equal(http.userAgent, undefined);
});

test("v1 rejects omitted mode fields and plugin-owned credentials", async () => {
  const provider = { async request() { throw new Error("unreachable"); } };
  const signal = new AbortController().signal;
  for (const invalid of [
    request({ presentation: undefined }),
    request({ transport: undefined }),
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
