import assert from "node:assert/strict";
import {
  appendFile,
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { RuntimeDiagnosticAttachmentSpool } from "../dist/diagnostics/attachment-spool.js";
import {
  runtimeDiagnosticValue,
  validateRuntimeDiagnosticCapturePolicy,
} from "../dist/diagnostics/contracts.js";
import { RuntimeDiagnosticsManager } from "../dist/diagnostics/manager.js";
import { RuntimeDiagnosticsHttpClient } from "../dist/diagnostics/http.js";
import {
  containsForbiddenRuntimeDiagnosticText,
  serializeRuntimeDiagnosticTree,
} from "../dist/diagnostics/privacy.js";
import { runtimeDiagnosticEvents } from "../dist/diagnostics/registry.js";
import { RuntimeDiagnosticsService } from "../dist/diagnostics/service.js";

test("restrictedRaw remains unsupported until the D5 security decision", () => {
  assert.throws(
    () => validateRuntimeDiagnosticCapturePolicy({
      components: new Set(["runtime.http"]),
      durationMillis: 1_000,
      maxStoredBytes: 1_024,
      origins: new Set(),
      payloadKind: "restrictedRaw",
    }),
    /unsupported/,
  );
});

test("dynamic tree preserves cycles without invoking getters or retaining secrets", () => {
  const canary = "MGREAD_SECRET_CANARY_TREE_73f33d";
  let getterCalls = 0;
  const value = { token: canary, title: "safe" };
  Object.defineProperty(value, "dangerous", {
    enumerable: true,
    get() {
      getterCalls += 1;
      return canary;
    },
  });
  value.self = value;

  const bytes = serializeRuntimeDiagnosticTree(value);
  const encoded = new TextDecoder().decode(bytes);
  assert.equal(getterCalls, 0);
  assert.equal(encoded.includes(canary), false);
  assert.match(encoded, /"kind":"redacted"/);
  assert.match(encoded, /"kind":"ref"/);
  assert.match(encoded, /"typeName":"accessor"/);
});

test("manager writes one terminal, rejects duplicate end, and isolates writer failures", async () => {
  const committed = [];
  const writer = {
    defaultSessionId: "default-session-0001",
    sourceRunId: "runtime-source-run-0001",
    appendEvents(events) {
      committed.push(...events);
    },
  };
  const manager = new RuntimeDiagnosticsManager(writer, {
    batchSize: 16,
    maxBatchDelayMillis: 10_000,
  });
  const span = manager.startSpan({ definition: runtimeDiagnosticEvents.lifecycle });
  span.end("success", {
    attributes: () => runtimeDiagnosticValue.object({
      stage: runtimeDiagnosticValue.string("ready"),
    }),
  });
  assert.throws(() => span.end("error"), /exactly once/);
  await manager.flush();
  const spanEvents = committed.filter((event) => event.spanId === span.trace.spanId);
  assert.equal(spanEvents.filter((event) => event.phase === "start").length, 1);
  assert.equal(spanEvents.filter((event) => event.phase === "terminal").length, 1);

  const broken = new RuntimeDiagnosticsManager({
    defaultSessionId: "default-session-0002",
    sourceRunId: "runtime-source-run-0002",
    appendEvents() {
      throw new Error("injected writer failure");
    },
  }, { maxBatchDelayMillis: 10_000 });
  assert.doesNotThrow(() => broken.emit({ definition: runtimeDiagnosticEvents.lifecycle }));
  await broken.flush();
  assert.equal(broken.statistics.writerErrors, 1);
  await broken.close();
  await manager.close();
});

test("attachment spool applies fixed pressure without blocking its producer", async () => {
  const spool = new RuntimeDiagnosticAttachmentSpool(64);
  assert.equal(spool.offer(new Uint8Array(40)), true);
  assert.equal(spool.offer(new Uint8Array(40)), false);
  assert.equal(spool.completion.captureState, "pressureDropped");
  assert.equal(spool.completion.rawByteLength, 80);
  const chunks = [];
  for await (const chunk of spool) chunks.push(chunk);
  assert.equal(chunks.length, 1);
  assert.equal(chunks[0].byteLength, 40);
  assert.equal(spool.queueHighWater, 40);
});

test("Runtime service persists paged events and safe structured detail TXT", async (t) => {
  const dataRoot = await mkdtemp(join(tmpdir(), "mgread-runtime-diagnostics-"));
  const service = await RuntimeDiagnosticsService.open({
    dataRoot,
    manager: { maxBatchDelayMillis: 10_000 },
  });
  t.after(async () => {
    await service.close();
    await rm(dataRoot, { force: true, recursive: true });
  });
  const session = await service.startCapture({
    components: new Set(["runtime.diagnostics"]),
    durationMillis: 60_000,
    maxStoredBytes: 1024 * 1024,
    origins: new Set(),
    payloadKind: "safeStructured",
  });
  const event = service.manager.emit({
    definition: runtimeDiagnosticEvents.attachment,
  });
  assert.ok(event);
  await service.manager.flush();

  const canary = "MGREAD_SECRET_CANARY_STORE_b973e1";
  const descriptor = await service.captureStructuredAttachment({
    eventId: event.eventId,
    kind: "structured.tree",
    value: { nested: { password: canary }, visible: [1, 2, 3] },
  });
  assert.ok(descriptor);
  assert.equal(descriptor.captureState, "captured");
  const chunk = await service.readAttachment(descriptor.attachmentId, {
    length: 64 * 1024,
    offset: 0,
  });
  assert.equal(chunk.eof, true);
  const decoded = Buffer.from(chunk.bytesBase64, "base64").toString("utf8");
  assert.equal(decoded.includes(canary), false);
  assert.equal(containsForbiddenRuntimeDiagnosticText(decoded, [canary]), false);

  await service.stopCapture(session.sessionId);
  await service.manager.flush();
  const eventPage = await service.listEvents({ sessionId: session.sessionId }, undefined, 1);
  assert.equal(eventPage.items.length, 1);
  assert.ok(eventPage.nextCursor);
  const secondPage = await service.listEvents(
    { sessionId: session.sessionId },
    eventPage.nextCursor,
    200,
  );
  assert.ok(secondPage.items.length >= 1);
  const attachments = await service.listAttachments(event.eventId);
  assert.equal(attachments.length, 1);
  assert.equal(attachments[0].attachmentId, descriptor.attachmentId);

  await service.close();
  const files = await listFiles(dataRoot);
  for (const file of files) {
    assert.equal(file.endsWith(".txt"), true, `non-TXT diagnostics file: ${file}`);
    assert.equal(/(?:sqlite|\.db|-wal|-shm)/i.test(file), false, file);
    const bytes = await readFile(file);
    assert.equal(bytes.includes(Buffer.from(canary)), false, `canary leaked into ${file}`);
  }
});

test("memory-only debug details never create a detail file", async (t) => {
  const dataRoot = await mkdtemp(join(tmpdir(), "mgread-runtime-memory-details-"));
  const service = await RuntimeDiagnosticsService.open({
    dataRoot,
    manager: { maxBatchDelayMillis: 10_000 },
  });
  t.after(async () => {
    await service.close();
    await rm(dataRoot, { force: true, recursive: true });
  });
  const session = await service.startCapture({
    components: new Set(["runtime.http"]),
    detailStorage: "memoryOnly",
    durationMillis: 60_000,
    maxStoredBytes: 64 * 1024,
    origins: new Set(),
    payloadKind: "contentPayload",
  });
  const event = service.manager.emit({ definition: runtimeDiagnosticEvents.http });
  assert.ok(event);
  const capture = service.beginTextAttachment({
    eventId: event.eventId,
    formatId: "text",
    kind: "http.response.body",
    mediaType: "text/html",
    privacyClass: "content",
  });
  assert.ok(capture);
  const body = Buffer.from("<html>only-live-debug</html>");
  assert.equal(capture.offer(body), true);
  capture.finish();
  const descriptor = await capture.result;
  const statistics = await service.getStorageStatistics();
  assert.equal(statistics.detailTextBytes, 0);
  assert.ok(statistics.memoryDetailBytes > 0);
  const chunk = await service.readAttachment(descriptor.attachmentId, {
    length: 64 * 1024,
    offset: 0,
  });
  assert.equal(Buffer.from(chunk.bytesBase64, "base64").toString("utf8"), body.toString("utf8"));

  await service.stopCapture(session.sessionId);
  assert.equal((await service.getStorageStatistics()).memoryDetailBytes, 0);
  await assert.rejects(
    service.readAttachment(descriptor.attachmentId, { length: 1024, offset: 0 }),
    /does not exist/,
  );
  const files = await listFiles(dataRoot);
  assert.equal(files.some((file) => file.includes(`${join("diagnostics", "details")}`)), false);
});

test("explicit debug capture preserves and redacts large minified JSON", async (t) => {
  const dataRoot = await mkdtemp(join(tmpdir(), "mgread-runtime-large-json-"));
  const service = await RuntimeDiagnosticsService.open({
    dataRoot,
    manager: { maxBatchDelayMillis: 10_000 },
  });
  t.after(async () => {
    await service.close();
    await rm(dataRoot, { force: true, recursive: true });
  });
  const session = await service.startCapture({
    components: new Set(["runtime.http"]),
    detailStorage: "persistToText",
    durationMillis: 60_000,
    maxStoredBytes: 1024 * 1024,
    origins: new Set(),
    payloadKind: "contentPayload",
  });
  const event = service.manager.emit({ definition: runtimeDiagnosticEvents.http });
  assert.ok(event);
  const capture = service.beginTextAttachment(
    {
      charset: "utf-8",
      eventId: event.eventId,
      formatId: "json",
      kind: "http.response.body",
      mediaType: "application/json",
      privacyClass: "content",
    },
    512 * 1024,
  );
  assert.ok(capture);
  const canary = "MGREAD_LARGE_JSON_SECRET_2f97";
  const body = JSON.stringify({
    password: canary,
    payload: "x".repeat(256 * 1024),
    tail: "large-json-kept",
  });
  assert.equal(capture.offer(Buffer.from(body)), true);
  capture.finish();
  const descriptor = await capture.result;
  assert.equal(descriptor.captureState, "captured");

  const chunks = [];
  for (let offset = 0; offset < descriptor.storedByteLength; offset += 64 * 1024) {
    const chunk = await service.readAttachment(descriptor.attachmentId, {
      length: 64 * 1024,
      offset,
    });
    chunks.push(Buffer.from(chunk.bytesBase64, "base64"));
  }
  const decoded = Buffer.concat(chunks).toString("utf8");
  assert.equal(decoded.includes(canary), false);
  assert.equal(decoded.includes("large-json-kept"), true);
  assert.equal(decoded.includes("<redacted-long-line>"), false);
  await service.stopCapture(session.sessionId);
});

test("default HTTP diagnostics never clones or persists a response body", async (t) => {
  const dataRoot = await mkdtemp(join(tmpdir(), "mgread-runtime-metadata-http-"));
  const service = await RuntimeDiagnosticsService.open({
    dataRoot,
    manager: { maxBatchDelayMillis: 10_000 },
  });
  const originalFetch = globalThis.fetch;
  let cloneCalls = 0;
  const response = new Response("DEFAULT_BODY_CANARY_c247", {
    headers: { "content-type": "text/html" },
    status: 200,
  });
  Object.defineProperty(response, "clone", {
    value() {
      cloneCalls += 1;
      return new Response("DEFAULT_BODY_CANARY_c247", {
        headers: { "content-type": "text/html" },
        status: 200,
      });
    },
  });
  globalThis.fetch = async () => response;
  t.after(async () => {
    globalThis.fetch = originalFetch;
    await service.close();
    await rm(dataRoot, { force: true, recursive: true });
  });

  const client = new RuntimeDiagnosticsHttpClient(service);
  const result = await client.fetch("https://example.test/chapter?id=secret", {});
  assert.equal(result, response);
  assert.equal(cloneCalls, 0);
  await service.manager.flush();
  for (const file of await listFiles(dataRoot)) {
    const text = await readFile(file, "utf8");
    assert.equal(text.includes("DEFAULT_BODY_CANARY_c247"), false, file);
  }
});

test("startup truncates a partial TXT line and recovers the interrupted run", async (t) => {
  const dataRoot = await mkdtemp(join(tmpdir(), "mgread-runtime-tail-recovery-"));
  const first = await RuntimeDiagnosticsService.open({
    dataRoot,
    manager: { maxBatchDelayMillis: 10_000 },
  });
  first.manager.emit({ definition: runtimeDiagnosticEvents.lifecycle });
  await first.manager.flush();
  const priorSession = (await first.listSessions()).items[0];
  assert.ok(priorSession);
  const eventFiles = (await listFiles(join(dataRoot, "diagnostics", "events")))
    .filter((file) => file.endsWith(".txt"));
  assert.ok(eventFiles.length > 0);
  const tail = eventFiles.at(-1);
  assert.ok(tail);
  await appendFile(tail, '{"partial":true}', "utf8");

  const second = await RuntimeDiagnosticsService.open({
    dataRoot,
    manager: { maxBatchDelayMillis: 10_000 },
  });
  t.after(async () => {
    await second.close();
    await first.close();
    await rm(dataRoot, { force: true, recursive: true });
  });
  const sessions = await second.listSessions();
  const recovered = sessions.items.find(
    (session) => session.sessionId === priorSession.sessionId,
  );
  assert.equal(recovered?.state, "ended");
  for (const file of eventFiles) {
    const text = await readFile(file, "utf8");
    assert.equal(text.includes('"partial":true'), false);
    assert.equal(text.endsWith("\n"), true);
  }
});

test("legacy diagnostics databases are removed before TXT startup", async (t) => {
  const dataRoot = await mkdtemp(join(tmpdir(), "mgread-runtime-legacy-"));
  const diagnosticsRoot = join(dataRoot, "diagnostics");
  const objectsRoot = join(diagnosticsRoot, "objects");
  await mkdir(objectsRoot, { recursive: true });
  const legacy = [
    join(diagnosticsRoot, "index.sqlite"),
    join(diagnosticsRoot, "index.sqlite-wal"),
    join(diagnosticsRoot, "index.sqlite-shm"),
    join(objectsRoot, "legacy.bin"),
  ];
  await Promise.all(legacy.map((file) => writeFile(file, "legacy")));
  const service = await RuntimeDiagnosticsService.open({ dataRoot });
  t.after(async () => {
    await service.close();
    await rm(dataRoot, { force: true, recursive: true });
  });
  for (const file of legacy) {
    await assert.rejects(readFile(file));
  }
  for (const file of await listFiles(diagnosticsRoot)) {
    assert.equal(file.endsWith(".txt"), true, file);
  }
});

test("content attachment redacts authorization and query values", async (t) => {
  const dataRoot = await mkdtemp(join(tmpdir(), "mgread-runtime-http-diagnostics-"));
  const service = await RuntimeDiagnosticsService.open({
    dataRoot,
    manager: { maxBatchDelayMillis: 10_000 },
  });
  t.after(async () => {
    await service.close();
    await rm(dataRoot, { force: true, recursive: true });
  });
  const session = await service.startCapture({
    components: new Set(["runtime.http"]),
    durationMillis: 60_000,
    maxStoredBytes: 1024 * 1024,
    origins: new Set(),
    payloadKind: "contentPayload",
  });
  const event = service.manager.emit({ definition: runtimeDiagnosticEvents.http });
  assert.ok(event);
  const capture = service.beginTextAttachment({
    charset: "utf-8",
    eventId: event.eventId,
    formatId: "text",
    kind: "http.response.body",
    mediaType: "text/plain",
    privacyClass: "content",
  });
  assert.ok(capture);
  const canary = "MGREAD_HTTP_CANARY_65a90d";
  assert.equal(
    capture.offer(Buffer.from(`Authorization: Bearer ${canary}\n/path?q=${canary}\nbody=visible\n`)),
    true,
  );
  capture.finish();
  const descriptor = await capture.result;
  const chunk = await service.readAttachment(descriptor.attachmentId, {
    length: 64 * 1024,
    offset: 0,
  });
  const decoded = Buffer.from(chunk.bytesBase64, "base64").toString("utf8");
  assert.equal(decoded.includes(canary), false);
  assert.match(decoded, /Authorization: <redacted>/);
  assert.match(decoded, /\?q=<redacted>/);
  await service.stopCapture(session.sessionId);
});

async function listFiles(root) {
  const files = [];
  for (const entry of await readdir(root, { withFileTypes: true })) {
    const path = join(root, entry.name);
    if (entry.isDirectory()) files.push(...await listFiles(path));
    else if (entry.isFile()) files.push(path);
  }
  return files;
}
