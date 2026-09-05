import assert from "node:assert/strict";
import test from "node:test";

import {
  makeDevelopmentPluginEvent,
  makeError,
  parseRuntimeCancellation,
  parseRuntimeRequest,
} from "../dist/protocol.js";
import { protocolVersion } from "../dist/runtime-version.js";

const bootId = "test-boot-id";
const nowUnixMs = 1_000_000;

/** Creates a valid request baseline so each assertion changes one field only. */
function request(overrides = {}) {
  return {
    v: protocolVersion,
    type: "request",
    bootId,
    id: "c:request",
    method: "runtime.ping",
    traceId: "trace:request",
    deadlineUnixMs: String(nowUnixMs + 1),
    idempotencyKey: null,
    params: {},
    ...overrides,
  };
}

/** Creates a valid response-free cancellation baseline for parser tests. */
function cancellation(overrides = {}) {
  return {
    v: protocolVersion,
    type: "cancel",
    bootId,
    id: "c:cancel",
    targetId: "c:request",
    traceId: "trace:cancel",
    ...overrides,
  };
}

test("desktop protocol parser accepts the bounded bootstrap request shape", () => {
  const parsed = parseRuntimeRequest(request(), bootId, nowUnixMs);

  assert.equal(parsed.ok, true);
  if (!parsed.ok) {
    throw new Error("Expected a valid Runtime request.");
  }
  assert.deepEqual(parsed.request, {
    v: protocolVersion,
    bootId,
    id: "c:request",
    method: "runtime.ping",
    traceId: "trace:request",
    deadlineUnixMs: String(nowUnixMs + 1),
    idempotencyKey: null,
    params: {},
  });
});

test("desktop protocol parser maps incompatible, stale and cross-boot requests to stable errors", () => {
  const incompatible = parseRuntimeRequest(request({ v: "2.0" }), bootId, nowUnixMs);
  assert.equal(incompatible.ok, false);
  if (!incompatible.ok) {
    assert.deepEqual(incompatible.error, {
      code: "version_incompatible",
      message: "The Runtime protocol version is incompatible.",
      requestId: "c:request",
      traceId: "trace:request",
    });
  }

  const expired = parseRuntimeRequest(
    request({ deadlineUnixMs: String(nowUnixMs) }),
    bootId,
    nowUnixMs,
  );
  assert.equal(expired.ok, false);
  if (!expired.ok) {
    assert.equal(expired.error.code, "timeout");
  }

  const wrongBoot = parseRuntimeRequest(
    request({ bootId: "other-boot" }),
    bootId,
    nowUnixMs,
  );
  assert.equal(wrongBoot.ok, false);
  if (!wrongBoot.ok) {
    assert.equal(wrongBoot.error.code, "invalid_request");
  }
});

test("desktop protocol never writes an orphan error envelope", () => {
  assert.equal(
    makeError(bootId, {
      code: "invalid_request",
      message: "Malformed frame.",
      requestId: undefined,
      traceId: undefined,
    }),
    undefined,
  );
});

test("source media resolution failures cross the protocol as retryable stable errors", () => {
  const envelope = makeError(bootId, {
    code: "source_media_resolution_failed",
    message: "The source could not resolve an external media address.",
    requestId: "c:media",
    traceId: "trace:media",
  });

  assert.equal(envelope?.error.code, "source_media_resolution_failed");
  assert.equal(envelope?.error.retryable, true);
});

test("source access blocks cross the protocol as retryable stable errors", () => {
  const envelope = makeError(bootId, {
    code: "source_access_blocked",
    message: "访问异常，请稍后再试。\n注释：当前 IP 可能异常，请更换 IP 后重试。",
    requestId: "c:access",
    traceId: "trace:access",
  });

  assert.equal(envelope?.error.code, "source_access_blocked");
  assert.equal(envelope?.error.message, "访问异常，请稍后再试。\n注释：当前 IP 可能异常，请更换 IP 后重试。");
  assert.equal(envelope?.error.retryable, true);
});

test("development change events expose revision and plugin identity without paths", () => {
  const event = makeDevelopmentPluginEvent(bootId, 7, [
    { kind: "updated", pluginId: "org.example.source" },
  ]);
  assert.deepEqual(event, {
    v: protocolVersion,
    type: "event",
    bootId,
    event: "development.plugins.changed",
    revision: 7,
    changes: [{ kind: "updated", pluginId: "org.example.source" }],
  });
  assert.equal(JSON.stringify(event).includes("path"), false);
});

test("desktop protocol parses only a matching client cancellation envelope", () => {
  const parsed = parseRuntimeCancellation(cancellation(), bootId);
  assert.equal(parsed.ok, true);
  if (!parsed.ok) {
    throw new Error("Expected a valid Runtime cancellation.");
  }
  assert.deepEqual(parsed.cancellation, {
    v: protocolVersion,
    bootId,
    id: "c:cancel",
    targetId: "c:request",
    traceId: "trace:cancel",
  });

  const invalidTarget = parseRuntimeCancellation(
    cancellation({ targetId: "s:server" }),
    bootId,
  );
  assert.equal(invalidTarget.ok, false);
  if (!invalidTarget.ok) {
    assert.equal(invalidTarget.error.code, "invalid_request");
  }
});
