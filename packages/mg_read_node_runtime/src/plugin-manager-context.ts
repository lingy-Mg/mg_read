/**
 * Builds the bounded Plugin API context owned by one Runtime Core.
 * Paths stay plugin-private; browser session state remains inside the host provider.
 */
import { mkdir } from "node:fs/promises";
import { resolve } from "node:path";

import {
  requestPluginBrowserInteraction,
  requestPluginBrowserSession,
  type PluginBrowserSessionProvider,
} from "./plugin-browser-session.js";
import type { PluginHttpRequestInit } from "@mgread/source-api";
import type { PluginPackageDescriptor } from "./plugin-package.js";
import { pluginApiVersion } from "./plugin-package.js";
import { runtimeVersion } from "./runtime-version.js";
import type {
  MgReadPluginContext,
  PluginInvocationScope,
  PluginManagerEvent,
  PluginManagerEventSink,
  PluginPublicError,
  PluginPublicErrorCode,
  PluginRuntimeHttpClient,
} from "./plugin-manager-contract.js";
import { PluginManagerError } from "./plugin-manager-contract.js";
import { createPluginWebViewApi } from "./plugin-webview-page.js";

export async function createPluginContext(options: {
  readonly browserSession: PluginBrowserSessionProvider | undefined;
  readonly dataRoot: string;
  readonly descriptor: PluginPackageDescriptor;
  readonly debugLogEnabled: () => boolean;
  readonly events: PluginManagerEventSink;
  readonly http: PluginRuntimeHttpClient;
  readonly invocationScope: () => PluginInvocationScope | undefined;
}): Promise<Omit<MgReadPluginContext, "resource">> {
  const { browserSession, dataRoot, descriptor, events, http, invocationScope, debugLogEnabled } = options;
  const dataDir = resolve(dataRoot, "plugin-data", descriptor.id);
  const cacheDir = resolve(dataRoot, "plugin-cache", descriptor.id);
  await Promise.all([mkdir(dataDir, { recursive: true }), mkdir(cacheDir, { recursive: true })]);
  const emitLog = (
    logLevel: NonNullable<PluginManagerEvent["logLevel"]>,
    logMessage: string,
    logCategory: NonNullable<PluginManagerEvent["logCategory"]> = "plugin.custom",
  ): void => {
    if (debugLogEnabled()) events({ code: "plugin_log_emitted", logCategory, logLevel, logMessage, outcome: "success", pluginId: descriptor.id });
  };
  const withScope = <T>(operation: (scope: PluginInvocationScope) => Promise<T>): Promise<T> => {
    const scope = invocationScope();
    if (scope === undefined) throw new PluginManagerError("invalid_request");
    return operation(scope);
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
    webview: createPluginWebViewApi({
      log: (level, message) => emitLog(level, message, "plugin.webview"),
      pluginId: descriptor.id,
      pluginName: descriptor.displayName,
      provider: browserSession,
      withScope,
    }),
    cacheDir,
    dataDir,
    errors: Object.freeze({
      raise: (errorOrCode: PluginPublicError | PluginPublicErrorCode): never => {
        const error = typeof errorOrCode === "string"
          ? defaultPublicError(errorOrCode)
          : normalizePublicError(errorOrCode);
        if (error === undefined) throw new PluginManagerError("invalid_request");
        throw new PluginManagerError(error.code, error.detail);
      },
    }),
    http: Object.freeze({ fetch: (input: string | URL, init: PluginHttpRequestInit = {}) => {
      const scope = invocationScope();
      const signals: AbortSignal[] = [];
      if (scope !== undefined) {
        signals.push(scope.signal, AbortSignal.timeout(Math.max(1, Number(scope.deadlineUnixMs) - Date.now())));
      }
      const { proxyMode: requestedProxyMode, ...requestInit } = init;
      const proxyMode = requestedProxyMode === "direct" ? requestedProxyMode : undefined;
      if (requestInit.signal != null) signals.push(requestInit.signal);
      if (debugLogEnabled()) emitLog("debug", `HTTP 请求：地址=${String(input)}，初始化参数=${JSON.stringify(init)}`, "plugin.http");
      const startedAt = performance.now();
      return http.fetch(input, {
        ...requestInit,
        redirect: requestInit.redirect ?? "follow",
        ...(signals.length === 0 ? {} : { signal: signals.length === 1 ? signals[0] : AbortSignal.any(signals) }),
      }, scope?.trace, proxyMode).then((response) => {
        if (debugLogEnabled()) {
          emitLog("debug", `HTTP 响应：状态=${response.status}，耗时毫秒=${Math.round(performance.now() - startedAt)}，响应头=${JSON.stringify(Object.fromEntries(response.headers))}`, "plugin.http");
          void response.clone().text().then((body) => emitLog("debug", `HTTP 响应预览：正文=${body.slice(0, 2000)}`, "plugin.http"), () => emitLog("warn", "HTTP 响应预览失败", "plugin.http"));
        }
        return response;
      }, (error) => { if (debugLogEnabled()) emitLog("error", `HTTP 请求出错：耗时毫秒=${Math.round(performance.now() - startedAt)}，错误=${error instanceof Error ? error.name : "unknown"}`, "plugin.http"); throw error; });
    } }),
    log: Object.freeze({
      debug: (message: string) => emitLog("debug", message),
      error: (message: string) => emitLog("error", message),
      info: (message: string) => emitLog("info", message),
      warn: (message: string) => emitLog("warn", message),
    }),
    plugin: Object.freeze({ id: descriptor.id, version: descriptor.version }),
  });

}

const maximumPublicErrorTextLength = 512;

function defaultPublicError(code: PluginPublicErrorCode): { readonly code: PluginPublicErrorCode; readonly detail?: string } | undefined {
  if (code === "source_media_resolution_failed") return { code };
  if (code === "source_access_blocked") return { code, detail: "访问异常，请稍后再试。" };
  return undefined;
}

function normalizePublicError(error: PluginPublicError): { readonly code: PluginPublicErrorCode; readonly detail: string } | undefined {
  const code = error?.code;
  if (code !== "source_access_blocked" && code !== "source_media_resolution_failed") return undefined;
  const message = boundedPublicErrorText(error.message);
  if (message === undefined) return undefined;
  const annotation = boundedPublicErrorText(error.annotation);
  return {
    code,
    detail: annotation === undefined ? message : `${message}\n注释：${annotation}`,
  };
}

function boundedPublicErrorText(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const normalized = value.replace(/\u0000/gu, "").trim();
  if (normalized.length === 0) return undefined;
  return normalized.length <= maximumPublicErrorTextLength
    ? normalized
    : `${normalized.slice(0, maximumPublicErrorTextLength)}…`;
}
