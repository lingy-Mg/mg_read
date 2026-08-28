/**
 * Builds the bounded Plugin API context owned by one Runtime Core.
 * Paths stay plugin-private; browser credentials remain inside the host provider.
 */
import { mkdir } from "node:fs/promises";
import { resolve } from "node:path";

import {
  requestPluginBrowserInteraction,
  requestPluginBrowserSession,
  type PluginBrowserSessionProvider,
} from "./plugin-browser-session.js";
import type { PluginPackageDescriptor } from "./plugin-package.js";
import { pluginApiVersion } from "./plugin-package.js";
import { runtimeVersion } from "./runtime-version.js";
import type {
  MgReadPluginContext,
  PluginInvocationScope,
  PluginManagerEvent,
  PluginManagerEventSink,
  PluginRuntimeHttpClient,
} from "./plugin-manager-contract.js";
import { PluginManagerError } from "./plugin-manager-contract.js";

export async function createPluginContext(options: {
  readonly browserSession: PluginBrowserSessionProvider | undefined;
  readonly dataRoot: string;
  readonly descriptor: PluginPackageDescriptor;
  readonly events: PluginManagerEventSink;
  readonly http: PluginRuntimeHttpClient;
  readonly invocationScope: () => PluginInvocationScope | undefined;
}): Promise<Omit<MgReadPluginContext, "resource">> {
  const { browserSession, dataRoot, descriptor, events, http, invocationScope } = options;
  const dataDir = resolve(dataRoot, "plugin-data", descriptor.id);
  const cacheDir = resolve(dataRoot, "plugin-cache", descriptor.id);
  await Promise.all([mkdir(dataDir, { recursive: true }), mkdir(cacheDir, { recursive: true })]);
  const emitLog = (logLevel: NonNullable<PluginManagerEvent["logLevel"]>, logMessage: string): void => {
    events({ code: "plugin_log_emitted", logLevel, logMessage, outcome: "success", pluginId: descriptor.id });
  };
  return Object.freeze({
    app: Object.freeze({ nodeVersion: process.versions.node, pluginApi: pluginApiVersion, runtimeVersion }),
    browser: Object.freeze({ sessionV1: Object.freeze({
      request: (request: unknown) => withScope(scope =>
        requestPluginBrowserSession(browserSession, descriptor.id, request, scope.signal, scope.deadlineUnixMs)),
      requestCoordinates: (request: unknown) => withScope(scope =>
        requestPluginBrowserInteraction(browserSession, descriptor.id, {
          ...(request as Record<string, unknown>),
          action: "coordinates",
        }, scope.signal, scope.deadlineUnixMs)),
      nativeInput: (request: unknown) => withScope(scope =>
        requestPluginBrowserInteraction(browserSession, descriptor.id, {
          ...(request as Record<string, unknown>),
          action: "native-input",
        }, scope.signal, scope.deadlineUnixMs)),
      controlClick: (request: unknown) => withScope(scope =>
        requestPluginBrowserInteraction(browserSession, descriptor.id, {
          ...(request as Record<string, unknown>),
          action: "control-click",
        }, scope.signal, scope.deadlineUnixMs)),
    }) }),
    cacheDir,
    dataDir,
    http: Object.freeze({ fetch: (input: string | URL, init: RequestInit = {}) => {
      const scope = invocationScope();
      const signals: AbortSignal[] = [];
      if (scope !== undefined) {
        signals.push(scope.signal, AbortSignal.timeout(Math.max(1, Number(scope.deadlineUnixMs) - Date.now())));
      }
      if (init.signal != null) signals.push(init.signal);
      return http.fetch(input, {
        ...init,
        redirect: init.redirect ?? "follow",
        ...(signals.length === 0 ? {} : { signal: signals.length === 1 ? signals[0] : AbortSignal.any(signals) }),
      }, scope?.trace);
    } }),
    log: Object.freeze({
      debug: (message: string) => emitLog("debug", message),
      error: (message: string) => emitLog("error", message),
      info: (message: string) => emitLog("info", message),
      warn: (message: string) => emitLog("warn", message),
    }),
    plugin: Object.freeze({ id: descriptor.id, version: descriptor.version }),
  });

  function withScope<T>(
    operation: (scope: PluginInvocationScope) => Promise<T>,
  ): Promise<T> {
    const scope = invocationScope();
    if (scope === undefined) throw new PluginManagerError("invalid_request");
    return operation(scope);
  }
}
