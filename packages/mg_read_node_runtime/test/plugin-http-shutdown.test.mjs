/** Shutdown must abort unread upstream bodies, including retired proxy agents. */
import assert from "node:assert/strict";
import http from "node:http";
import net from "node:net";
import test from "node:test";
import { ConfigurablePluginHttpClient } from "../dist/plugin-http-client.js";

for (const mode of ["system", "direct", "proxy", "retired-proxy"]) {
  test(`Runtime HTTP shutdown completes with a stalled ${mode} body`, {timeout: 5000}, async (t) => {
    const sockets = new Set();
    const origin = http.createServer((_request, response) => {
      response.writeHead(200, {"Content-Type": "text/plain"});
      response.write("unfinished");
    });
    const proxy = http.createServer();
    proxy.on("connect", (request, downstream, head) => {
      const target = new URL(`http://${request.url}`);
      const upstream = net.connect(Number(target.port), target.hostname, () => {
        downstream.write("HTTP/1.1 200 Connection Established\r\n\r\n");
        if (head.length) upstream.write(head);
        downstream.pipe(upstream).pipe(downstream);
      });
      sockets.add(upstream);
      upstream.on("error", () => downstream.destroy());
      downstream.on("close", () => upstream.destroy());
    });
    const client = new ConfigurablePluginHttpClient({noProxy: "*"});
    t.after(async () => {
      for (const socket of sockets) socket.destroy();
      origin.closeAllConnections();
      proxy.closeAllConnections();
      await client.close();
      await Promise.all([origin, proxy].map(server => new Promise(resolve => server.close(resolve))));
    });
    for (const server of [origin, proxy]) {
      server.on("connection", socket => sockets.add(socket));
      await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
    }
    if (mode.includes("proxy")) client.configure(`http://127.0.0.1:${proxy.address().port}`);
    const response = await client.fetch(`http://127.0.0.1:${origin.address().port}`, {}, undefined,
      mode === "direct" ? "direct" : undefined);
    assert.equal(response.status, 200);
    if (mode === "retired-proxy") client.configure(undefined);
    const started = performance.now();
    let timer;
    try {
      await Promise.race([client.close(), new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error("shutdown waited for the upstream body")), 2000);
      })]);
    } finally { clearTimeout(timer); }
    t.diagnostic(`shutdown with ${mode}: ${Math.round(performance.now() - started)} ms`);
    await assert.rejects(response.text());
  });
}
