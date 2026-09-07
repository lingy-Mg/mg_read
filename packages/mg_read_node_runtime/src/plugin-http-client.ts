/**
 * Runtime-owned HTTP client used only by the public `ctx.http.fetch` API.
 *
 * Responsibilities:
 * - follow Node's system/environment proxy by default while allowing HTTP/2
 *   negotiation with transparent HTTP/1.1 fallback;
 * - route plugin HTTP and Runtime source-resource requests directly through
 *   one explicitly configured upstream proxy with the same negotiation;
 * - supply the Runtime-owned reduced desktop Chrome user-agent unless a
 *   source explicitly overrides it;
 * - switch future requests without mutating process environment or global fetch.
 *
 * Notes:
 * - the app supplies the upstream HTTP, HTTPS or SOCKS5 URL;
 * - existing requests retain the dispatcher sampled when they started.
 */
import {
  Agent,
  EnvHttpProxyAgent,
  ProxyAgent,
  Socks5ProxyAgent,
  type Dispatcher,
} from "undici";

import type {
  PluginRuntimeHttpClient,
  PluginRuntimeHttpProxyMode,
  PluginRuntimeTraceContext,
} from "./plugin-manager-contract.js";

/** Chrome Stable 152.0.7977.64 reduced desktop UA, verified on 2026-08-31. */
export const defaultPluginUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36";

const http2TlsOptions = Object.freeze({ allowH2: true as const });

type Socks5Http2Options = NonNullable<ConstructorParameters<typeof Socks5ProxyAgent>[1]> & {
  readonly requestTls: {
    readonly ALPNProtocols: readonly ["h2", "http/1.1"];
  };
};
const socks5Http2Options: Socks5Http2Options = Object.freeze({
  requestTls: Object.freeze({ ALPNProtocols: ["h2", "http/1.1"] as const }),
});

export interface PluginHttpEnvironmentProxyOptions {
  readonly httpProxy?: string;
  readonly httpsProxy?: string;
  readonly noProxy?: string;
}

export class ConfigurablePluginHttpClient implements PluginRuntimeHttpClient {
  readonly #directAgent: Dispatcher;
  readonly #systemProxyAgent: Dispatcher;
  #proxyAgent: Dispatcher | undefined;
  #proxyUrl: string | undefined;
  readonly #retiring = new Set<Promise<void>>();

  constructor(environmentProxy: PluginHttpEnvironmentProxyOptions = {}) {
    this.#directAgent = new Agent(http2TlsOptions);
    this.#systemProxyAgent = new EnvHttpProxyAgent({
      allowH2: true,
      requestTls: http2TlsOptions,
      ...environmentProxy,
    });
  }

  configure(proxyUrl: string | undefined): void {
    if (this.#proxyUrl === proxyUrl) return;
    const next = proxyUrl === undefined
      ? undefined
      : proxyUrl.startsWith("socks5:")
        ? new Socks5ProxyAgent(proxyUrl, socks5Http2Options)
        : new ProxyAgent({
            allowH2: true,
            requestTls: http2TlsOptions,
            uri: proxyUrl,
          });
    const previous = this.#proxyAgent;
    this.#proxyAgent = next;
    this.#proxyUrl = proxyUrl;
    if (previous !== undefined) this.#retire(previous);
  }

  fetch(
    input: string | URL,
    init: RequestInit,
    _trace?: PluginRuntimeTraceContext,
    proxyMode?: PluginRuntimeHttpProxyMode,
  ): Promise<Response> {
    const requestInit = withDefaultUserAgent(init);
    const dispatcher = proxyMode === "direct"
      ? this.#directAgent
      : this.#proxyAgent ?? this.#systemProxyAgent;
    const proxiedInit = { ...requestInit, dispatcher } as RequestInit & { readonly dispatcher: Dispatcher };
    return fetch(input, proxiedInit);
  }

  async close(): Promise<void> {
    const current = this.#proxyAgent;
    this.#proxyAgent = undefined;
    this.#proxyUrl = undefined;
    if (current !== undefined) this.#retire(current);
    this.#retire(this.#directAgent);
    this.#retire(this.#systemProxyAgent);
    await Promise.allSettled([...this.#retiring]);
  }

  #retire(agent: Dispatcher): void {
    let operation: Promise<void>;
    operation = agent.close().catch(() => {}).finally(() => this.#retiring.delete(operation));
    this.#retiring.add(operation);
  }
}

function withDefaultUserAgent(init: RequestInit): RequestInit {
  const headers = new Headers(init.headers);
  if (!headers.has("user-agent")) headers.set("user-agent", defaultPluginUserAgent);
  return { ...init, headers };
}
