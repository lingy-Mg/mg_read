/**
 * Per-request HTTP failure context, carried on the existing Error cause chain.
 * Observes Undici only while awaiting headers; never logs or persists traffic.
 * AsyncLocalStorage separates concurrent calls and proxy changes. URL values
 * contain origins only; credentials, paths, queries and headers are excluded.
 */
import { AsyncLocalStorage } from "node:async_hooks";
import { channel } from "node:diagnostics_channel";
import type { Socket } from "node:net";
import { runtimeVersion } from "./runtime-version.js";

interface HttpObservation {
  requestOrigin?: string | undefined;
  proxyTunnelOrigin?: string | undefined;
  connectionTarget?: string | undefined;
  connectionErrorCode?: string | undefined;
  tcpAttemptAddress?: string;
  tcpAttemptPort?: number;
}
const observations = new AsyncLocalStorage<HttpObservation>();

export function httpDiagnosticOrigin(value: string | URL | undefined): string | undefined {
  if (value === undefined) return undefined;
  try {
    const url = new URL(value);
    return `${url.protocol}//${url.host}`;
  } catch { return undefined; }
}

export function withHttpFailureContext(
  context: Readonly<Record<string, string | undefined>>,
  operation: () => Promise<Response>,
  failureContext: () => Readonly<Record<string, string>> = () => ({}),
): Promise<Response> {
  const observed: HttpObservation = {};
  const subscriptions: (() => void)[] = [];
  const subscribe = (name: string, read: (message: unknown) => void): void => {
    const source = channel(name);
    const listener = (message: unknown): void => {
      if (observations.getStore() !== observed) return;
      try { read(message); } catch { /* Observation must not change the request. */ }
    };
    source.subscribe(listener);
    subscriptions.push(() => source.unsubscribe(listener));
  };
  subscribe("undici:request:create", message => {
    const { request } = message as { request: { origin: string; method: string } };
    if (request.method === "CONNECT") observed.proxyTunnelOrigin = httpDiagnosticOrigin(request.origin);
    else observed.requestOrigin = httpDiagnosticOrigin(request.origin);
  });
  subscribe("net.client.socket", message => {
    const { socket } = message as { socket: Socket };
    const onAttempt = (address: string, port: number): void => {
      observed.tcpAttemptAddress = address;
      observed.tcpAttemptPort = port;
    };
    socket.on("connectionAttempt", onAttempt);
    subscriptions.push(() => socket.off("connectionAttempt", onAttempt));
  });
  for (const name of ["beforeConnect", "connectError"]) {
    subscribe(`undici:client:${name}`, message => {
      const { connectParams, error } = message as {
        connectParams?: { protocol: string; host: string };
        error?: { code?: string };
      };
      observed.connectionTarget = connectParams === undefined ? undefined
        : httpDiagnosticOrigin(`${connectParams.protocol}//${connectParams.host}`);
      if (typeof error?.code === "string") observed.connectionErrorCode = error.code.slice(0, 80);
    });
  }
  return observations.run(observed, async () => {
    try {
      return await operation();
    } catch (cause) {
      const detail = JSON.stringify({
        platform: process.platform, architecture: process.arch,
        nodeVersion: process.versions.node, runtimeVersion,
        ...context, ...observed, ...failureContext(),
        // No connection event can also mean connection reuse or pre-connect failure.
        connectionObservation: observed.connectionTarget === undefined ? "not_observed" : "observed",
        tcpObservation: observed.tcpAttemptAddress === undefined ? "not_observed" : "observed",
      });
      throw new Error(`HTTP request context=${detail}`, { cause });
    } finally {
      for (const unsubscribe of subscriptions) unsubscribe();
    }
  });
}
