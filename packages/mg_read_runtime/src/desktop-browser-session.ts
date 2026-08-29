/**
 * Desktop reverse bridge for the platform-owned browser.session.v1 provider.
 *
 * The Node Core sends only validated, bounded requests over its existing
 * authenticated WebSocket. Cookie, user-agent, WebView handles and profile
 * paths never enter this process or the plugin API.
 */
import { randomUUID } from "node:crypto";

import {
  PluginBrowserSessionError,
  type PluginBrowserHostRequest,
  type PluginBrowserSessionInteractionRequest,
  type PluginBrowserSessionRequest,
  type PluginBrowserSessionProvider,
} from "./plugin-browser-session.js";
import type { JsonObject } from "./protocol.js";
import { protocolVersion } from "./runtime-version.js";
import { maxWebSocketControlFrameBytes, ServerWebSocketSession } from "./websocket.js";

const maximumPendingHostRequests = 16;
const hostErrorCodes = new Set([
  "cancelled",
  "interaction_required",
  "overloaded",
  "plugin_execution_failed",
  "timeout",
  "unsupported",
] as const);

interface PendingHostRequest {
  readonly reject: (error: Error) => void;
  readonly resolve: (response: unknown) => void;
  readonly session: ServerWebSocketSession;
  readonly traceId: string;
}

/** One host-facing channel shared by every desktop plugin invocation. */
export class DesktopBrowserSessionBroker implements PluginBrowserSessionProvider {
  readonly #bootId: string;
  readonly #pending = new Map<string, PendingHostRequest>();
  #host: ServerWebSocketSession | undefined;

  constructor(bootId: string) {
    this.#bootId = bootId;
  }

  attach(session: ServerWebSocketSession): void {
    this.#host = session;
  }

  detach(session: ServerWebSocketSession): void {
    if (this.#host === session) this.#host = undefined;
    for (const [id, pending] of this.#pending) {
      if (pending.session !== session) continue;
      this.#pending.delete(id);
      pending.reject(new PluginBrowserSessionError("unsupported"));
    }
  }

  request(request: PluginBrowserHostRequest): Promise<unknown> {
    const session = this.#host;
    if (session === undefined || session.isClosed) {
      throw new PluginBrowserSessionError("unsupported");
    }
    if (this.#pending.size >= maximumPendingHostRequests) {
      throw new PluginBrowserSessionError("overloaded");
    }
    if (request.signal.aborted) {
      throw new PluginBrowserSessionError("cancelled");
    }

    const id = `s:browser-${randomUUID()}`;
    const traceId = `trace:${id}`;
    const runtimeOperation = (request as { readonly operation?: string }).operation;
    const params = runtimeOperation === "interaction"
      ? interactionParameters(request)
      : runtimeOperation?.startsWith("page.") === true
        ? pageParameters(request)
        : legacyParameters(request);
    const envelope = JSON.stringify({
      v: protocolVersion,
      type: "host_request",
      bootId: this.#bootId,
      id,
      method: "host.browserSession.v1",
      traceId,
      deadlineUnixMs: String(Date.now() + request.timeoutMs),
      params,
    });
    if (Buffer.byteLength(envelope, "utf8") > maxWebSocketControlFrameBytes) {
      throw new PluginBrowserSessionError("overloaded");
    }

    return new Promise<unknown>((resolve, reject) => {
      const onAbort = (): void => {
        if (!this.#pending.delete(id)) return;
        try {
          session.sendText(JSON.stringify({
            v: protocolVersion,
            type: "host_cancel",
            bootId: this.#bootId,
            id: `s:cancel-${randomUUID()}`,
            targetId: id,
            traceId,
          }));
        } catch {
          // The invocation deadline/cancellation remains authoritative.
        }
        reject(new PluginBrowserSessionError("cancelled"));
      };
      request.signal.addEventListener("abort", onAbort, { once: true });
      this.#pending.set(id, {
        reject: (error) => {
          request.signal.removeEventListener("abort", onAbort);
          reject(error);
        },
        resolve: (response) => {
          request.signal.removeEventListener("abort", onAbort);
          resolve(response);
        },
        session,
        traceId,
      });
      try {
        session.sendText(envelope);
      } catch {
        this.#pending.delete(id);
        request.signal.removeEventListener("abort", onAbort);
        reject(new PluginBrowserSessionError("unsupported"));
      }
    });
  }

  /** Consumes only server-direction host replies; normal client RPC returns false. */
  handleIncoming(session: ServerWebSocketSession, value: unknown): boolean {
    if (!isObject(value) || (value.type !== "host_response" && value.type !== "host_error")) {
      return false;
    }
    const id = typeof value.id === "string" ? value.id : "";
    const pending = this.#pending.get(id);
    if (
      pending === undefined ||
      pending.session !== session ||
      value.v !== protocolVersion ||
      value.bootId !== this.#bootId ||
      value.traceId !== pending.traceId
    ) {
      session.close(1002, "Runtime host response envelope is invalid.");
      return true;
    }
    this.#pending.delete(id);
    if (value.type === "host_error") {
      const code = isObject(value.error) && typeof value.error.code === "string"
        ? value.error.code
        : "plugin_execution_failed";
      pending.reject(new PluginBrowserSessionError(
        hostErrorCodes.has(code as never) ? code as never : "plugin_execution_failed",
      ));
      return true;
    }
    if (!isObject(value.result)) {
      pending.reject(new PluginBrowserSessionError("plugin_execution_failed"));
      return true;
    }
    pending.resolve(value.result);
    return true;
  }
}

function isObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function pageParameters(request: PluginBrowserHostRequest): Readonly<Record<string, unknown>> {
  const { signal: _signal, ...params } = request;
  return params;
}

function legacyParameters(request: PluginBrowserHostRequest): Readonly<Record<string, unknown>> {
  const value = request as PluginBrowserSessionRequest & { readonly pluginId: string };
  return {
    operation: "request",
    version: value.version,
    pluginId: value.pluginId,
    sessionKey: value.sessionKey,
    url: value.url,
    method: value.method,
    headers: value.headers,
    body: value.body,
    interaction: value.interaction,
    presentation: value.presentation,
    transport: value.transport,
    timeoutMs: value.timeoutMs,
    maxResponseBytes: value.maxResponseBytes,
  };
}

function interactionParameters(request: PluginBrowserHostRequest): Readonly<Record<string, unknown>> {
  const value = request as PluginBrowserSessionInteractionRequest & { readonly pluginId: string };
  return {
    operation: "interaction",
    action: value.action,
    version: value.version,
    pluginId: value.pluginId,
    sessionKey: value.sessionKey,
    url: value.url,
    selector: value.selector,
    presentation: value.presentation,
    timeoutMs: value.timeoutMs,
    ...(value.text === undefined ? {} : { text: value.text }),
  };
}
