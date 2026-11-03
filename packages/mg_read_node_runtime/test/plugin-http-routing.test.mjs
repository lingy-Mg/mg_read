/** Real sockets distinguish a refused proxy endpoint from an origin failure. */
import assert from "node:assert/strict";
import { channel } from "node:diagnostics_channel";
import http from "node:http";
import net from "node:net";
import test from "node:test";
import { ConfigurablePluginHttpClient } from "../dist/plugin-http-client.js";

const loopback = "127.173.137.161";

async function server(t, handler, host = loopback) {
  const instance = http.createServer(handler);
  const sockets = new Set();
  instance.on("connection", socket => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
  });
  await new Promise((resolve, reject) => {
    instance.once("error", reject);
    instance.listen(0, host, resolve);
  });
  t.after(async () => {
    for (const socket of sockets) socket.destroy();
    await new Promise(resolve => instance.close(resolve));
  });
  return { instance, port: instance.address().port, url: `http://${host}:${instance.address().port}` };
}

function client(t, environment) {
  const value = new ConfigurablePluginHttpClient(environment);
  t.after(() => value.close());
  return value;
}

for (const noProxy of ["localhost,127.0.0.1,::1", "127.0.0.0/8"]) {
  test(`system routing bypasses all literal loopback destinations (${noProxy})`, { timeout: 5000 }, async t => {
    const origin = await server(t, (_request, response) => response.end("local"));
    const proxy = await server(t);
    let tunnels = 0;
    proxy.instance.on("connect", (_request, socket) => {
      tunnels++;
      socket.end("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n");
    });
    const httpClient = client(t, { httpProxy: proxy.url, httpsProxy: proxy.url, noProxy });
    assert.equal(await (await httpClient.fetch(origin.url, {})).text(), "local");
    assert.equal(tunnels, 0);
  });
}

test("system routing reevaluates loopback after a remote redirect", { timeout: 5000 }, async t => {
  const origin = await server(t, (_request, response) => response.end("redirected-local"));
  const redirect = await server(t, (_request, response) => {
    response.writeHead(302, { location: origin.url });
    response.end();
  });
  const proxy = await server(t);
  const tunnels = [];
  proxy.instance.on("connect", (request, downstream) => {
    tunnels.push(request.url);
    if (request.url !== "remote.invalid:80") {
      downstream.end("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n");
      return;
    }
    const upstream = net.connect(redirect.port, loopback, () => {
      downstream.write("HTTP/1.1 200 Connection Established\r\n\r\n");
      downstream.pipe(upstream).pipe(downstream);
    });
    downstream.on("close", () => upstream.destroy());
    upstream.on("error", () => downstream.destroy());
  });
  const httpClient = client(t, { httpProxy: proxy.url, noProxy: "" });
  assert.equal(await (await httpClient.fetch("http://remote.invalid/", {})).text(), "redirected-local");
  assert.deepEqual(tunnels, ["remote.invalid:80"]);
});

for (const mode of ["system", "explicit"]) {
  test(`a refused ${mode} loopback proxy preserves TCP evidence; rebinding recovers`, { timeout: 5000 }, async t => {
    const oldProxy = await server(t);
    await new Promise(resolve => oldProxy.instance.close(resolve));
    const tcpErrors = [];
    const observer = ({ connectParams, error }) => tcpErrors.push({ connectParams, error });
    const events = channel("undici:client:connectError");
    events.subscribe(observer);
    t.after(() => events.unsubscribe(observer));
    const httpClient = client(t, { httpProxy: oldProxy.url, httpsProxy: oldProxy.url, noProxy: "" });
    if (mode === "explicit") httpClient.configure(oldProxy.url);
    await assert.rejects(httpClient.fetch("https://remote.invalid/content", {}), error => {
      assert.equal(error.cause.code, "ECONNREFUSED");
      assert.equal(error.cause.address, loopback);
      assert.equal(error.cause.port, oldProxy.port);
      return true;
    });
    assert.ok(tcpErrors.some(({ connectParams }) =>
      connectParams.hostname === loopback && Number(connectParams.port) === oldProxy.port));
    // No DNS or TCP connection to remote.invalid is needed to obtain this error.
    const origin = await server(t, (_request, response) => response.end("rebound"));
    const newProxy = await server(t);
    let tunnels = 0;
    newProxy.instance.on("connect", (_request, socket) => {
      tunnels++;
      const upstream = net.connect(origin.port, loopback, () => {
        socket.write("HTTP/1.1 200 Connection Established\r\n\r\n");
        socket.pipe(upstream).pipe(socket);
      });
      socket.on("close", () => upstream.destroy());
      upstream.on("error", () => socket.destroy());
    });
    httpClient.configure(newProxy.url);
    assert.equal(await (await httpClient.fetch("http://remote.invalid/content", {})).text(), "rebound");
    assert.equal(tunnels, 1);
    assert.equal(await (await httpClient.fetch(origin.url, {}, undefined, "direct")).text(), "rebound");
    assert.equal(tunnels, 1);
  });
}
