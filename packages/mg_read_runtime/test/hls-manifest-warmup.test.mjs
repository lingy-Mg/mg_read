/** Runtime-private HLS manifest warmup regression coverage. */
import assert from "node:assert/strict";
import test from "node:test";

import { HlsManifestWarmup } from "../dist/hls-manifest-warmup.js";
import { SourceResourceCoordinator } from "../dist/source-resource-coordinator.js";
import { encodeSourceResourceToken } from "../dist/source-resource-token.js";

test("shares in-flight root work and follows only one child playlist", async () => {
  const calls = [];
  let releaseRoot;
  const rootGate = new Promise((resolve) => { releaseRoot = resolve; });
  const fetch = async (input, init) => {
    const url = String(input);
    calls.push({ headers: init.headers, url });
    if (url.endsWith("root.m3u8")) {
      await rootGate;
      return responseAt(url, "#EXTM3U\nchild.m3u8\n");
    }
    return responseAt(url, "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n#EXTINF:4,\nsegment.ts\n");
  };
  const warmup = new HlsManifestWarmup();
  const root = sourceEntry("https://media.example/root.m3u8", fetch);
  warmup.schedule("org.example.video", root);
  const first = warmup.open("org.example.video", root, {}, new AbortController().signal);
  const second = warmup.open("org.example.video", root, {}, new AbortController().signal);
  releaseRoot();

  const [firstResource, secondResource] = await Promise.all([first, second]);
  assert.equal(await firstResource.response.text(), "#EXTM3U\nchild.m3u8\n");
  assert.equal(await secondResource.response.text(), "#EXTM3U\nchild.m3u8\n");
  await waitFor(() => calls.length === 2);
  assert.deepEqual(calls.map((call) => call.url), [
    "https://media.example/root.m3u8",
    "https://media.example/child.m3u8",
  ]);
});

test("does not prefetch multi-variant children, media segments, or keys", async () => {
  const calls = [];
  const fetch = async (input) => {
    const url = String(input);
    calls.push(url);
    return responseAt(url, "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\na.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=2\nb.m3u8\n");
  };
  const warmup = new HlsManifestWarmup();
  const root = sourceEntry("https://media.example/master.m3u8", fetch);
  warmup.schedule("org.example.video", root);
  await warmup.open("org.example.video", root, {}, new AbortController().signal);
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(calls, ["https://media.example/master.m3u8"]);
});

test("Range bypasses cache and failed warmup falls back to live forwarding", async () => {
  let calls = 0;
  const fetch = async (input, init) => {
    calls += 1;
    if (calls === 1) return responseAt(String(input), "unavailable", { status: 503 });
    assert.equal(init.headers.range, "bytes=0-31");
    return responseAt(String(input), "#EXTM3U\n", { status: 206 });
  };
  const warmup = new HlsManifestWarmup();
  const root = sourceEntry("https://media.example/root.m3u8", fetch);
  warmup.schedule("org.example.video", root);
  const resource = await warmup.open(
    "org.example.video",
    root,
    { range: "bytes=0-31" },
    new AbortController().signal,
  );
  assert.equal(resource.response.status, 206);
  assert.equal(calls, 2);
});

test("expires after 15 seconds and retains at most eight entries with concurrency two", async () => {
  let now = 1_000;
  let active = 0;
  let maximumActive = 0;
  const counts = new Map();
  const fetch = async (input) => {
    const url = String(input);
    counts.set(url, (counts.get(url) ?? 0) + 1);
    active += 1;
    maximumActive = Math.max(maximumActive, active);
    await new Promise((resolve) => setImmediate(resolve));
    active -= 1;
    return responseAt(url, "#EXTM3U\n#EXTINF:4,\nsegment.ts\n");
  };
  const warmup = new HlsManifestWarmup(() => {}, () => now);
  const entries = Array.from({ length: 9 }, (_, index) => sourceEntry(`https://media.example/${index}.m3u8`, fetch));
  entries.forEach((entry) => warmup.schedule("org.example.video", entry));
  await Promise.all(entries.map((entry) => warmup.open("org.example.video", entry, {}, new AbortController().signal)));
  assert.ok(maximumActive <= 2);

  await warmup.open("org.example.video", entries[0], {}, new AbortController().signal);
  assert.ok(counts.get("https://media.example/0.m3u8") >= 2);
  const lastCountBeforeExpiry = counts.get("https://media.example/8.m3u8");
  now += 15_001;
  await warmup.open("org.example.video", entries[8], {}, new AbortController().signal);
  assert.equal(counts.get("https://media.example/8.m3u8"), lastCountBeforeExpiry + 1);
});

test("preserves the final redirected URL and cancellation remains invisible", async () => {
  const fetch = async () => responseAt("https://cdn.example/final/root.m3u8", "#EXTM3U\n");
  const warmup = new HlsManifestWarmup();
  const root = sourceEntry("https://media.example/root.m3u8", fetch);
  warmup.schedule("org.example.video", root);
  const resource = await warmup.open("org.example.video", root, {}, new AbortController().signal);
  assert.equal(resource.responseUrl, "https://cdn.example/final/root.m3u8");

  const cancellation = new AbortController();
  cancellation.abort();
  assert.equal(await warmup.open("org.example.video", root, {}, cancellation.signal), undefined);
});

test("resource diagnostics report bounded phases without URLs or headers", async () => {
  const events = [];
  const fetch = async (input) => responseAt(String(input), "#EXTM3U\n");
  const coordinator = new SourceResourceCoordinator(
    { fetch },
    (event) => events.push(event),
    () => true,
  );
  const request = {
    kind: "hls",
    url: "https://media.example/root.m3u8?signature=private",
    headers: { Authorization: "Bearer private", Referer: "https://source.example/private" },
  };
  coordinator.created("org.example.video", request, () => "http://127.0.0.1/resource");
  const token = encodeSourceResourceToken("org.example.video", request);
  const resource = await coordinator.open(
    token,
    {},
    new AbortController().signal,
    () => "http://127.0.0.1/resource",
  );
  resource.onServed(200, 9, 12.4);

  const messages = events.map((event) => event.logMessage ?? "").join("\n");
  assert.match(messages, /HLS清单预热/u);
  assert.match(messages, /资源代理响应/u);
  assert.doesNotMatch(messages, /media\.example|signature|Authorization|Bearer|source\.example/u);
});

function sourceEntry(url, fetch) {
  return {
    fetch,
    proxy: () => "http://127.0.0.1/resource",
    request: { kind: "hls", headers: {}, url },
  };
}

function responseAt(url, body, init = {}) {
  const response = new Response(body, init);
  Object.defineProperty(response, "url", { value: url });
  return response;
}

async function waitFor(predicate) {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setImmediate(resolve));
  }
  assert.fail("condition_not_reached");
}
