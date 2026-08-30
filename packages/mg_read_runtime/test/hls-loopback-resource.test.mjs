/**
 * Runtime HLS loopback resource regression coverage.
 *
 * Verifies that rewritten child playlists remain HLS resources while segments,
 * keys, maps, and low-latency parts use binary pass-through with Range forwarding.
 */
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { PluginManager } from "../dist/index.js";
import { serveSourceResource } from "../dist/loopback-resources.js";

const masterManifest = `#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="main",URI="audio/index.m3u8"
#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=50000,URI="iframe/index.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=1000000,AUDIO="audio"
media/index.m3u8
`;

const mediaManifest = `#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="../key.bin"
#EXT-X-MAP:URI="init.mp4"
#EXT-X-PART:DURATION=0.333,URI="part0.m4s"
#EXTINF:4.0,
segment0.ts
`;

test("HLS loopback keeps playlists recursive and streams binary children", async (t) => {
  const dataRoot = await mkdtemp(join(tmpdir(), "mgread-hls-loopback-"));
  t.after(() => rm(dataRoot, { force: true, recursive: true }));
  const calls = [];
  const manager = new PluginManager(dataRoot, {
    http: {
      async fetch(input, init) {
        const url = String(input);
        calls.push({ headers: init.headers, url });
        if (url.endsWith("master.m3u8")) {
          return responseAt(url, masterManifest, {
            headers: { "content-type": "application/vnd.apple.mpegurl" },
          });
        }
        if (url.endsWith(".m3u8")) {
          return responseAt(url, mediaManifest, {
            headers: { "content-type": "application/vnd.apple.mpegurl" },
          });
        }
        const range = init.headers.range;
        const body = Uint8Array.from([0x47, 0x40, 0x00, 0x10]);
        return responseAt(url, range === undefined ? body : body.slice(0, 1), {
          status: range === undefined ? 200 : 206,
          headers: {
            "accept-ranges": "bytes",
            "content-range": range === undefined ? "bytes 0-3/4" : "bytes 0-0/4",
            "content-type": url.endsWith(".ts") ? "video/mp2t" : "application/octet-stream",
          },
        });
      },
    },
  });
  const server = createServer((request, response) => {
    const token = new URL(request.url ?? "/", "http://127.0.0.1").pathname.split("/").at(-1) ?? "";
    void serveSourceResource(manager, token, response, () => {}, request);
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  t.after(() => new Promise((resolve) => server.close(resolve)));
  const address = server.address();
  assert.notEqual(address, null);
  assert.equal(typeof address, "object");
  const origin = `http://127.0.0.1:${address.port}`;
  manager.setResourceOrigin(origin);

  const rootUrl = manager.createResourceUrl("org.example.video", {
    kind: "hls",
    url: "https://media.example/master.m3u8",
    headers: { Referer: "https://source.example/watch" },
  });
  const rootResponse = await fetch(rootUrl);
  assert.equal(rootResponse.status, 200);
  const rewrittenMaster = await rootResponse.text();
  const masterUrls = loopbackUrls(rewrittenMaster, origin);
  assert.equal(masterUrls.length, 3);

  for (const childUrl of masterUrls) {
    const childResponse = await fetch(childUrl);
    assert.equal(childResponse.status, 200);
    assert.match(childResponse.headers.get("content-type") ?? "", /application\/vnd\.apple\.mpegurl/u);
    assert.equal(loopbackUrls(await childResponse.text(), origin).length, 4);
  }

  const mediaResponse = await fetch(masterUrls.at(-1));
  const binaryUrls = loopbackUrls(await mediaResponse.text(), origin);
  const segmentResponse = await fetch(binaryUrls.at(-1), { headers: { Range: "bytes=0-0" } });
  assert.equal(segmentResponse.status, 206);
  assert.equal(segmentResponse.headers.get("content-type"), "video/mp2t");
  assert.deepEqual(new Uint8Array(await segmentResponse.arrayBuffer()), Uint8Array.from([0x47]));
  assert.equal(calls.at(-1).headers.range, "bytes=0-0");

  for (const binaryUrl of binaryUrls.slice(0, -1)) {
    const binaryResponse = await fetch(binaryUrl);
    assert.equal(binaryResponse.status, 200);
    assert.doesNotMatch(binaryResponse.headers.get("content-type") ?? "", /mpegurl/u);
    assert.deepEqual(new Uint8Array(await binaryResponse.arrayBuffer()), Uint8Array.from([0x47, 0x40, 0x00, 0x10]));
  }
});

function loopbackUrls(manifest, origin) {
  const urls = [];
  for (const line of manifest.split(/\r?\n/u)) {
    if (line.startsWith(`${origin}/v1/source-resource/`)) urls.push(line);
    for (const match of line.matchAll(/URI="([^"]+)"/gu)) {
      if (match[1].startsWith(`${origin}/v1/source-resource/`)) urls.push(match[1]);
    }
  }
  return urls;
}

function responseAt(url, body, init) {
  const response = new Response(body, init);
  Object.defineProperty(response, "url", { value: url });
  return response;
}
