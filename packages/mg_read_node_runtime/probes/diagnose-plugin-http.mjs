/**
 * One bounded GET through the production plugin HTTP client, with TCP evidence.
 * Run after npm run build with the pinned Node. This is a separate process,
 * not a read of the running App's effective proxy or historical trace.
 * Emits origins/endpoints and errno only, never headers, bodies or credentials.
 */
import { channel } from "node:diagnostics_channel";
import { ConfigurablePluginHttpClient } from "../dist/plugin-http-client.js";

const [target, route = "system", ...extra] = process.argv.slice(2);
if (!target || extra.length || !URL.canParse(target) ||
    !["http:", "https:"].includes(new URL(target).protocol) ||
    (route !== "system" && route !== "direct" &&
      (!URL.canParse(route) || !["http:", "https:", "socks5:"].includes(new URL(route).protocol)))) {
  console.error("Usage: node probes/diagnose-plugin-http.mjs <http(s)-URL> [system|direct|proxy-URL]");
  process.exit(2);
}

const emit = (event, values) => console.log(JSON.stringify({
  at: new Date().toISOString(), pid: process.pid, event, ...values,
}));
const origin = value => {
  try { return new URL(value).origin; } catch { return undefined; }
};
function failure(error, depth = 0) {
  if (!error || depth >= 4) return undefined;
  return {
    name: error.name, code: error.code, syscall: error.syscall,
    address: error.address, port: error.port,
    cause: failure(error.cause, depth + 1),
    errors: Array.isArray(error.errors) ? error.errors.slice(0, 8).map(item => failure(item, depth + 1)) : undefined,
  };
}
const subscriptions = [];
function observe(name, callback) {
  const source = channel(name);
  source.subscribe(callback);
  subscriptions.push(() => source.unsubscribe(callback));
}
for (const name of ["beforeConnect", "connected", "connectError"]) {
  observe(`undici:client:${name}`, ({ connectParams, socket, error }) => emit(name, {
    hostname: connectParams?.hostname, port: connectParams?.port, protocol: connectParams?.protocol,
    remoteAddress: socket?.remoteAddress, remotePort: socket?.remotePort,
    error: failure(error),
  }));
}
observe("undici:request:create", ({ request }) => emit("request", {
  origin: origin(request.origin), method: request.method,
}));
observe("net.client.socket", ({ socket }) => {
  socket.on("lookup", (error, address, family, host) => emit("lookup", { host, address, family, error: failure(error) }));
  socket.on("connectionAttempt", (address, port, family) => emit("connectionAttempt", { address, port, family }));
});

const client = new ConfigurablePluginHttpClient();
try {
  if (route !== "system" && route !== "direct") client.configure(route);
  emit("configuration", {
    targetOrigin: origin(target), route: route === "system" || route === "direct" ? route : "explicit",
    proxyOrigin: origin(route),
    httpProxyOrigin: origin(process.env.http_proxy ?? process.env.HTTP_PROXY),
    httpsProxyOrigin: origin(process.env.https_proxy ?? process.env.HTTPS_PROXY ?? process.env.http_proxy ?? process.env.HTTP_PROXY),
    noProxy: process.env.no_proxy ?? process.env.NO_PROXY ?? "",
    nodeVersion: process.versions.node,
  });
  const response = await client.fetch(target, { signal: AbortSignal.timeout(10_000) }, undefined,
    route === "direct" ? "direct" : undefined);
  emit("response", { status: response.status, finalOrigin: origin(response.url), redirected: response.redirected });
  await response.body?.cancel();
} catch (error) {
  emit("failure", { error: failure(error) });
  process.exitCode = 1;
} finally {
  await client.close();
  for (const unsubscribe of subscriptions) unsubscribe();
}
