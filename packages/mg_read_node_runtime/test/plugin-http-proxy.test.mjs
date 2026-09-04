import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import http from "node:http";
import net from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { DesktopRuntime, PluginInstaller } from "../dist/index.js";
import { ConfigurablePluginHttpClient, defaultPluginUserAgent } from "../dist/plugin-http-client.js";

test("plugin HTTP client switches future requests between system and explicit proxy routing", async (t) => {
  let originRequests = 0;
  const userAgents = [];
  const origin = http.createServer((request, response) => {
    originRequests += 1;
    userAgents.push(request.headers["user-agent"] ?? null);
    response.end(`origin-${originRequests}`);
  });
  await listen(origin);

  let proxyTunnels = 0;
  const proxy = http.createServer();
  proxy.on("connect", (request, downstream, head) => {
    proxyTunnels += 1;
    const target = new URL(`http://${request.url}`);
    const upstream = net.connect(Number(target.port), target.hostname, () => {
      downstream.write("HTTP/1.1 200 Connection Established\r\n\r\n");
      if (head.length > 0) upstream.write(head);
      downstream.pipe(upstream);
      upstream.pipe(downstream);
    });
    upstream.on("error", () => downstream.destroy());
  });
  await listen(proxy);

  let socksTunnels = 0;
  const socks = createSocks5Proxy(() => socksTunnels += 1);
  await listen(socks);

  const client = new ConfigurablePluginHttpClient({ noProxy: "*" });
  t.after(async () => {
    await client.close();
    await close(socks);
    await close(proxy);
    await close(origin);
  });
  const originAddress = origin.address();
  const proxyAddress = proxy.address();
  const socksAddress = socks.address();
  assert.notEqual(originAddress, null);
  assert.notEqual(typeof originAddress, "string");
  assert.notEqual(proxyAddress, null);
  assert.notEqual(typeof proxyAddress, "string");
  assert.notEqual(socksAddress, null);
  assert.notEqual(typeof socksAddress, "string");
  const target = `http://127.0.0.1:${originAddress.port}/content`;

  assert.equal(await (await client.fetch(target, {})).text(), "origin-1");
  assert.equal(proxyTunnels, 0);

  client.configure(`http://127.0.0.1:${proxyAddress.port}/`);
  assert.equal(await (await client.fetch(target, {})).text(), "origin-2");
  assert.equal(proxyTunnels, 1);

  client.configure(undefined);
  assert.equal(await (await client.fetch(target, {})).text(), "origin-3");
  assert.equal(proxyTunnels, 1);

  client.configure(`socks5://127.0.0.1:${socksAddress.port}/`);
  assert.equal(await (await client.fetch(target, { headers: { "User-Agent": "source-specific" } })).text(), "origin-4");
  assert.equal(socksTunnels, 1);
  assert.equal(defaultPluginUserAgent, "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36");
  assert.deepEqual(userAgents, [defaultPluginUserAgent, defaultPluginUserAgent, defaultPluginUserAgent, "source-specific"]);
});

test("plugin HTTP client follows the environment proxy when no explicit override exists", async (t) => {
  const origin = http.createServer((_request, response) => response.end("system"));
  await listen(origin);
  let proxyTunnels = 0;
  const proxy = http.createServer();
  proxy.on("connect", (request, downstream, head) => {
    proxyTunnels += 1;
    const target = new URL(`http://${request.url}`);
    const upstream = net.connect(Number(target.port), target.hostname, () => {
      downstream.write("HTTP/1.1 200 Connection Established\r\n\r\n");
      if (head.length > 0) upstream.write(head);
      downstream.pipe(upstream);
      upstream.pipe(downstream);
    });
    upstream.on("error", () => downstream.destroy());
  });
  await listen(proxy);
  const originAddress = origin.address();
  const proxyAddress = proxy.address();
  assert.notEqual(originAddress, null);
  assert.notEqual(typeof originAddress, "string");
  assert.notEqual(proxyAddress, null);
  assert.notEqual(typeof proxyAddress, "string");
  const endpoint = `http://127.0.0.1:${proxyAddress.port}/`;
  const client = new ConfigurablePluginHttpClient({
    httpProxy: endpoint,
    httpsProxy: endpoint,
    noProxy: "",
  });
  t.after(async () => {
    await client.close();
    await close(proxy);
    await close(origin);
  });

  const response = await client.fetch(`http://127.0.0.1:${originAddress.port}/content`, {});

  assert.equal(await response.text(), "system");
  assert.equal(proxyTunnels, 1);
});

test("Runtime configuration routes the installed plugin ctx.http.fetch boundary only", async (t) => {
  let originRequests = 0;
  const userAgents = [];
  const origin = http.createServer((request, response) => {
    originRequests += 1;
    userAgents.push(request.headers["user-agent"] ?? null);
    response.end("ok");
  });
  await listen(origin);

  let proxyTunnels = 0;
  const proxy = http.createServer();
  proxy.on("connect", (request, downstream, head) => {
    proxyTunnels += 1;
    const target = new URL(`http://${request.url}`);
    const upstream = net.connect(Number(target.port), target.hostname, () => {
      downstream.write("HTTP/1.1 200 Connection Established\r\n\r\n");
      if (head.length > 0) upstream.write(head);
      downstream.pipe(upstream);
      upstream.pipe(downstream);
    });
    upstream.on("error", () => downstream.destroy());
  });
  await listen(proxy);

  const dataRoot = await mkdtemp(join(tmpdir(), "mgread-plugin-http-proxy-"));
  const project = await createHttpPlugin(join(dataRoot, "project"));
  await new PluginInstaller(dataRoot).installProject(project);
  const runtime = new DesktopRuntime({ dataRoot });
  t.after(async () => {
    await runtime.stop();
    await close(proxy);
    await close(origin);
    await rm(dataRoot, { force: true, recursive: true });
  });
  await runtime.start();
  const originAddress = origin.address();
  const proxyAddress = proxy.address();
  assert.notEqual(originAddress, null);
  assert.notEqual(typeof originAddress, "string");
  assert.notEqual(proxyAddress, null);
  assert.notEqual(typeof proxyAddress, "string");
  const target = `http://127.0.0.1:${originAddress.port}/content`;
  const deadline = () => Date.now() + 5_000;

  assert.deepEqual(
    await runtime.invokeEmbedded(
      "runtime.pluginHttpProxy.configure.v1",
      { proxyUrl: `http://127.0.0.1:${proxyAddress.port}/` },
      deadline(),
    ),
    { ok: true, result: { enabled: true } },
  );
  const proxied = await runtime.invokeEmbedded(
    "source.search.v1",
    { pluginId: "org.example.http-proxy", query: target, cursor: null, pageSize: 20 },
    deadline(),
  );
  assert.equal(proxied.ok, true);
  assert.equal(originRequests, 1);
  assert.equal(proxyTunnels, 1);

  await runtime.invokeEmbedded("runtime.pluginHttpProxy.configure.v1", { proxyUrl: null }, deadline());
  const direct = await runtime.invokeEmbedded(
    "source.search.v1",
    { pluginId: "org.example.http-proxy", query: target, cursor: null, pageSize: 20 },
    deadline(),
  );
  assert.equal(direct.ok, true);
  assert.equal(originRequests, 2);
  assert.equal(proxyTunnels, 1);
  assert.deepEqual(userAgents, [defaultPluginUserAgent, defaultPluginUserAgent]);
});

function listen(server) {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      server.off("error", reject);
      resolve();
    });
  });
}

function close(server) {
  return new Promise((resolve, reject) => {
    server.close((error) => error === undefined ? resolve() : reject(error));
  });
}

function createSocks5Proxy(onTunnel) {
  return net.createServer((downstream) => {
    let buffered = Buffer.alloc(0);
    let greeted = false;
    const read = (chunk) => {
      buffered = Buffer.concat([buffered, chunk]);
      if (!greeted) {
        if (buffered.length < 2) return;
        const greetingLength = 2 + buffered[1];
        if (buffered.length < greetingLength) return;
        buffered = buffered.subarray(greetingLength);
        greeted = true;
        downstream.write(Buffer.from([5, 0]));
      }
      if (buffered.length < 5) return;
      const addressType = buffered[3];
      const addressLength = addressType === 1 ? 4 : addressType === 4 ? 16 : 1 + buffered[4];
      const addressOffset = addressType === 3 ? 5 : 4;
      const requestLength = addressOffset + (addressType === 3 ? buffered[4] : addressLength) + 2;
      if (buffered.length < requestLength) return;
      const addressBytes = buffered.subarray(addressOffset, requestLength - 2);
      const host = addressType === 1
        ? [...addressBytes].join(".")
        : addressType === 3
          ? addressBytes.toString("utf8")
          : "::1";
      const port = buffered.readUInt16BE(requestLength - 2);
      const trailing = buffered.subarray(requestLength);
      downstream.off("data", read);
      onTunnel();
      const upstream = net.connect(port, host, () => {
        downstream.write(Buffer.from([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]));
        if (trailing.length > 0) upstream.write(trailing);
        downstream.pipe(upstream);
        upstream.pipe(downstream);
      });
      upstream.on("error", () => downstream.destroy());
    };
    downstream.on("data", read);
  });
}

async function createHttpPlugin(root) {
  await mkdir(join(root, "dist"), { recursive: true });
  const packageJson = {
    name: "@mgread-plugin/http-proxy-fixture",
    version: "1.0.0",
    type: "module",
    main: "dist/index.mjs",
    engines: { node: ">=24 <25" },
    mgread: {
      schemaVersion: 1,
      id: "org.example.http-proxy",
      displayName: "HTTP proxy fixture",
      pluginApi: 1,
      contentKinds: ["novel"],
    },
  };
  const lock = {
    name: packageJson.name,
    version: packageJson.version,
    lockfileVersion: 3,
    requires: true,
    packages: { "": { name: packageJson.name, version: packageJson.version } },
  };
  await Promise.all([
    writeFile(join(root, "package.json"), `${JSON.stringify(packageJson, null, 2)}\n`),
    writeFile(join(root, "package-lock.json"), `${JSON.stringify(lock, null, 2)}\n`),
    writeFile(
      join(root, "dist", "index.mjs"),
      `let context;
export function activate(next) { context = next; }
export function discover() { return { kind: "document", document: { components: [] } }; }
export async function search(request) {
  const response = await context.http.fetch(request.query);
  await response.text();
  return { items: [], nextCursor: null, totalCount: 0 };
}
export function getDetail() { throw new Error("unused"); }
export function getChapters() { throw new Error("unused"); }
export function getContent() { throw new Error("unused"); }
`,
    ),
  ]);
  return root;
}
