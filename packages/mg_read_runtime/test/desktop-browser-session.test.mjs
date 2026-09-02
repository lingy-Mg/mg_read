/** Desktop reverse browser host contract without a real WebView2 instance. */
import assert from "node:assert/strict";
import test from "node:test";

import { DesktopBrowserSessionBroker } from "../dist/desktop-browser-session.js";

function request(signal = new AbortController().signal) {
  return {
    version: 1,
    pluginId: "org.mgread.fixture",
    sessionKey: "fixture",
    url: "https://example.com/protected",
    method: "GET",
    headers: { accept: "text/html" },
    body: null,
    interaction: "allow",
    presentation: "visible",
    transport: "webview",
    timeoutMs: 5_000,
    maxResponseBytes: 4_096,
    signal,
    nativeClick: { x: 1, y: 1 },
    script: "document.querySelector('input').click()",
  };
}

function session() {
  return {
    isClosed: false,
    sent: [],
    sendText(value) { this.sent.push(JSON.parse(value)); },
    close() { this.isClosed = true; },
  };
}

test("desktop broker correlates one bounded host response without credentials", async () => {
  const broker = new DesktopBrowserSessionBroker("boot:fixture");
  const host = session();
  broker.attach(host);
  const pending = broker.request(request());
  const envelope = host.sent[0];
  assert.equal(envelope.type, "host_request");
  assert.equal(envelope.method, "host.browserSession.v1");
  assert.equal(envelope.params.pluginId, "org.mgread.fixture");
  assert.equal(envelope.params.headers.cookie, undefined);
  assert.equal(envelope.params.headers["user-agent"], undefined);
  assert.equal("signal" in envelope.params, false);
  assert.equal("nativeClick" in envelope.params, false);
  assert.equal("script" in envelope.params, false);

  assert.equal(broker.handleIncoming(host, {
    v: "1.2",
    type: "host_response",
    bootId: "boot:fixture",
    id: envelope.id,
    traceId: envelope.traceId,
    result: {
      version: 1,
      status: 200,
      finalUrl: "https://example.com/protected",
      headers: { "content-type": "text/html" },
      body: "ok",
    },
  }), true);
  assert.equal((await pending).body, "ok");
});

test("desktop broker cancels the exact reverse host job", async () => {
  const broker = new DesktopBrowserSessionBroker("boot:fixture");
  const host = session();
  broker.attach(host);
  const cancellation = new AbortController();
  const pending = broker.request(request(cancellation.signal));
  const requestEnvelope = host.sent[0];
  cancellation.abort();
  await assert.rejects(pending, (error) => error?.code === "cancelled");
  assert.equal(host.sent[1].type, "host_cancel");
  assert.equal(host.sent[1].targetId, requestEnvelope.id);
});

test("desktop broker reports unsupported until a negotiated Flutter host attaches", () => {
  const broker = new DesktopBrowserSessionBroker("boot:fixture");
  assert.throws(() => broker.request(request()), (error) => error?.code === "unsupported");
});

test("desktop broker forwards only a scoped WebView interaction", async () => {
  const broker = new DesktopBrowserSessionBroker("boot:fixture");
  const host = session();
  broker.attach(host);
  const pending = broker.request({
    operation: "interaction",
    action: "coordinates",
    version: 1,
    pluginId: "org.mgread.fixture",
    sessionKey: "fixture",
    url: "https://example.com/protected",
    selector: "#fixture-control",
    presentation: "hidden",
    timeoutMs: 5_000,
    signal: new AbortController().signal,
  });
  const envelope = host.sent[0];
  assert.deepEqual(envelope.params, {
    operation: "interaction",
    action: "coordinates",
    version: 1,
    pluginId: "org.mgread.fixture",
    sessionKey: "fixture",
    url: "https://example.com/protected",
    selector: "#fixture-control",
    presentation: "hidden",
    timeoutMs: 5_000,
  });
  broker.handleIncoming(host, {
    v: "1.2",
    type: "host_response",
    bootId: "boot:fixture",
    id: envelope.id,
    traceId: envelope.traceId,
    result: {
      version: 1,
      accepted: true,
      action: "coordinates",
      x: 12,
      y: 18,
      width: 80,
      height: 24,
    },
  });
  assert.equal((await pending).x, 12);
});

test("desktop broker forwards the source WebView debug control", async () => {
  const broker = new DesktopBrowserSessionBroker("boot:fixture");
  const host = session();
  broker.attach(host);
  const pending = broker.request({
    operation: "debug",
    action: "show",
    version: 1,
    pluginId: "org.mgread.fixture",
    pluginName: "Fixture Source",
    timeoutMs: 5_000,
    signal: new AbortController().signal,
  });
  const envelope = host.sent[0];
  assert.deepEqual(envelope.params, {
    operation: "debug",
    action: "show",
    version: 1,
    pluginId: "org.mgread.fixture",
    pluginName: "Fixture Source",
    timeoutMs: 5_000,
  });
  broker.handleIncoming(host, {
    v: "1.2",
    type: "host_response",
    bootId: "boot:fixture",
    id: envelope.id,
    traceId: envelope.traceId,
    result: { version: 1, accepted: true, action: "show" },
  });
  assert.equal((await pending).action, "show");
});
