/**
 * Plugin-facing single-page WebView capability.
 *
 * One plugin owns at most one host page. The Runtime validates operation shape
 * and JSON transport safety, serializes ordinary page work, and lets lifecycle
 * controls bypass that queue. It never filters script source or JSON fields.
 * Cookies, WebView handles and platform objects stay inside the host.
 */
import { PluginManagerError } from "./plugin-manager-contract.js";
import type {
  PluginJsonObject,
  PluginJsonValue,
  PluginWebViewApi,
  PluginWebViewCallOptions,
  PluginWebViewFetchRequest,
  PluginWebViewFetchResponse,
  PluginWebViewKey,
  PluginWebViewPage,
} from "@mgread/source-api";
import {
  browserSessionErrorCode,
  PluginBrowserSessionError,
  type PluginBrowserSessionProvider,
  type PluginWebViewHostRequest,
} from "./plugin-browser-session.js";

export type {
  PluginJsonObject,
  PluginJsonValue,
  PluginWebViewApi,
  PluginWebViewCallOptions,
  PluginWebViewFetchRequest,
  PluginWebViewFetchResponse,
  PluginWebViewKey,
  PluginWebViewPage,
} from "@mgread/source-api";

export const maximumWebViewTimeoutMs = 120_000;

type WebViewCallOptions = PluginWebViewCallOptions;

export function createPluginWebViewApi(options: {
  readonly log?: (level: "debug" | "error" | "info" | "warn", message: string) => void;
  readonly pluginId: string;
  readonly pluginName: string;
  readonly provider: PluginBrowserSessionProvider | undefined;
  readonly withScope: <T>(operation: (scope: {
    readonly deadlineUnixMs: string;
    readonly signal: AbortSignal;
  }) => Promise<T>) => Promise<T>;
}): PluginWebViewApi {
  const log = options.log ?? (() => {});
  let ordinaryTail: Promise<void> = Promise.resolve();
  const page = Object.freeze<PluginWebViewPage>({
    navigate: (url, callOptions) => invoke("page.navigate", { url: absoluteHttpUrl(url) }, callOptions).then(ignoreResult),
    async executeJavaScript<T extends PluginJsonValue = PluginJsonValue>(code: string, callOptions?: WebViewCallOptions): Promise<T> {
      const response = await invoke("page.evaluate", { code: nonEmptyString(code, 512 * 1024) }, callOptions);
      return readJsonValue(response, "value") as T;
    },
    async cdp<T extends PluginJsonValue = PluginJsonValue>(
      method: string,
      params?: PluginJsonObject,
      callOptions?: WebViewCallOptions,
    ): Promise<T> {
      const response = await invoke("page.cdp", {
        method: validateCdpMethod(method),
        params: validateCdpParams(params),
      }, callOptions);
      return readJsonValue(response, "value") as T;
    },
    getHtml: callOptions => invoke("page.html", {}, callOptions).then(response => readString(response, "html")),
    fetch: request => invoke("page.fetch", validateFetchRequest(request), request).then(readFetchResponse),
    click: request => invoke("page.click", validateCoordinates(request), request).then(ignoreResult),
    inputText: (text, callOptions) => invoke("page.input", { text: nonEmptyString(text, 64 * 1024) }, callOptions).then(ignoreResult),
    key: request => invoke("page.key", validateKeyRequest(request), request).then(ignoreResult),
    waitForText: request => invoke("page.waitText", validateWaitRequest(request), request)
      .then(response => Object.freeze({ url: readString(response, "url") })),
    getUrl: callOptions => invoke("page.getUrl", {}, callOptions).then(response => readString(response, "url")),
    show: callOptions => invoke("page.show", {}, callOptions).then(ignoreResult),
    hide: callOptions => invoke("page.hide", {}, callOptions).then(ignoreResult),
    close: callOptions => invoke("page.close", {}, callOptions).then(ignoreResult),
  });

  return Object.freeze<PluginWebViewApi>({
    open: async callOptions => {
      const visible = callOptions?.visible ?? false;
      if (typeof visible !== "boolean") invalid();
      await invoke("page.open", { visible }, callOptions);
      return page;
    },
  });

  function invoke(
    operation: PluginWebViewHostRequest["operation"],
    params: Readonly<Record<string, unknown>>,
    callOptions: WebViewCallOptions | undefined,
  ): Promise<unknown> {
    const timeoutMs = timeout(callOptions?.timeoutMs);
    return options.withScope(scope => {
      const execute = async (): Promise<unknown> => {
        log("debug", `WebView 请求：操作=${operation}，参数=${JSON.stringify(params)}`);
        if (options.provider === undefined) throw new PluginManagerError("unsupported");
        const remainingMs = Number(scope.deadlineUnixMs) - Date.now();
        if (scope.signal.aborted) throw new PluginManagerError("cancelled");
        if (!Number.isFinite(remainingMs) || remainingMs <= 0) throw new PluginManagerError("timeout");
        const timeoutSignal = AbortSignal.timeout(Math.max(1, Math.min(timeoutMs, remainingMs)));
        const signal = AbortSignal.any([scope.signal, timeoutSignal]);
        const request = Object.freeze({
          ...params,
          operation,
          pluginId: options.pluginId,
          pluginName: options.pluginName,
          signal,
          timeoutMs,
          version: 1 as const,
        }) as PluginWebViewHostRequest;
        try {
          const response = await options.provider.request(request);
          const hostErrorCode = browserSessionErrorCode(response);
          if (hostErrorCode !== undefined) throw new PluginManagerError(hostErrorCode);
          log("debug", `WebView 响应：操作=${operation}，结果=${JSON.stringify(response).slice(0, 2000)}`);
          return response;
        } catch (error) {
          log("error", `WebView 调用出错：操作=${operation}，错误=${error instanceof PluginManagerError ? error.code : error instanceof Error ? error.name : "unknown"}`);
          if (error instanceof PluginManagerError) throw error;
          if (isBrowserError(error)) throw new PluginManagerError(error.code);
          if (signal.aborted) throw new PluginManagerError(scope.signal.aborted ? "cancelled" : "timeout");
          throw new PluginManagerError("plugin_execution_failed");
        }
      };
      if (isControlOperation(operation)) return execute();
      const queued = ordinaryTail.then(execute, execute);
      ordinaryTail = queued.then(ignoreResult, ignoreResult);
      return queued;
    });
  }
}

function isControlOperation(operation: PluginWebViewHostRequest["operation"]): boolean {
  return operation === "page.open" || operation === "page.show" ||
    operation === "page.hide" || operation === "page.close";
}

function timeout(value: unknown): number {
  if (value === undefined) return 30_000;
  if (!Number.isSafeInteger(value) || (value as number) < 1 || (value as number) > maximumWebViewTimeoutMs) invalid();
  return value as number;
}

function validateFetchRequest(value: unknown): Readonly<Record<string, unknown>> {
  if (!isRecord(value)) invalid();
  const method = value.method === undefined ? "GET" : nonEmptyString(value.method, 32).toUpperCase();
  if (!/^[A-Z]+$/u.test(method)) invalid();
  const responseType = value.responseType ?? "text";
  if (responseType !== "text" && responseType !== "json" && responseType !== "base64") invalid();
  if (value.body !== undefined && value.body !== null && typeof value.body !== "string") invalid();
  if (!isRecord(value.headers ?? {})) invalid();
  const headers: Record<string, string> = {};
  for (const [name, header] of Object.entries(value.headers ?? {})) {
    if (typeof header !== "string" || name.length === 0 || name.length > 256 || header.length > 64 * 1024) invalid();
    headers[name] = header;
  }
  return Object.freeze({
    body: value.body ?? null,
    headers: Object.freeze(headers),
    method,
    responseType,
    url: absoluteHttpUrl(value.url),
  });
}

function validateCoordinates(value: unknown): Readonly<Record<string, unknown>> {
  if (!isRecord(value) || !finiteCoordinate(value.x) || !finiteCoordinate(value.y)) invalid();
  return Object.freeze({ x: value.x, y: value.y });
}

function validateCdpMethod(value: unknown): string {
  return nonEmptyString(value, 256);
}

function validateCdpParams(value: unknown): PluginJsonObject {
  if (value === undefined) return Object.freeze({});
  if (!isRecord(value) || !isJsonValue(value) || new TextEncoder().encode(JSON.stringify(value)).byteLength > 512 * 1024) invalid();
  return Object.freeze(value as PluginJsonObject);
}

function validateKeyRequest(value: unknown): Readonly<Record<string, unknown>> {
  if (!isRecord(value) || !webViewKeys.has(value.key as PluginWebViewKey)) invalid();
  const modifiers = value.modifiers ?? [];
  if (!Array.isArray(modifiers) || new Set(modifiers).size !== modifiers.length ||
      modifiers.some(item => item !== "alt" && item !== "control" && item !== "shift")) invalid();
  return Object.freeze({ key: value.key, modifiers: Object.freeze([...modifiers]) });
}

function validateWaitRequest(value: unknown): Readonly<Record<string, unknown>> {
  if (!isRecord(value)) invalid();
  const scope = value.scope ?? "text";
  if (scope !== "text" && scope !== "html") invalid();
  timeout(value.timeoutMs);
  return Object.freeze({ scope, text: nonEmptyString(value.text, 64 * 1024) });
}

function readFetchResponse(value: unknown): PluginWebViewFetchResponse {
  if (!isRecord(value) || !Number.isInteger(value.status) || (value.status as number) < 0 ||
      (value.status as number) > 599 || !isRecord(value.headers)) invalidResponse();
  const headers: Record<string, string> = {};
  for (const [name, header] of Object.entries(value.headers)) {
    if (typeof header !== "string") invalidResponse();
    headers[name] = header;
  }
  return Object.freeze({
    body: readJsonValue(value, "body"),
    headers: Object.freeze(headers),
    status: value.status as number,
    url: readString(value, "url"),
  });
}

function readJsonValue(value: unknown, key: string): PluginJsonValue {
  if (!isRecord(value) || !(key in value) || !isJsonValue(value[key])) invalidResponse();
  return value[key];
}

function readString(value: unknown, key: string): string {
  if (!isRecord(value) || typeof value[key] !== "string") invalidResponse();
  return value[key];
}

function ignoreResult(): void {}
function absoluteHttpUrl(value: unknown): string {
  const raw = nonEmptyString(value, 4096);
  try {
    const parsed = new URL(raw);
    if ((parsed.protocol !== "https:" && parsed.protocol !== "http:") || parsed.username || parsed.password) invalid();
    return parsed.toString();
  } catch { invalid(); }
}
function nonEmptyString(value: unknown, maximumLength: number): string {
  if (typeof value !== "string" || value.length === 0 || value.length > maximumLength) invalid();
  return value;
}
function finiteCoordinate(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 100_000;
}
function isJsonValue(value: unknown): value is PluginJsonValue {
  if (value === null || typeof value === "boolean" || typeof value === "string") return true;
  if (typeof value === "number") return Number.isFinite(value);
  if (Array.isArray(value)) return value.every(isJsonValue);
  return isRecord(value) && Object.values(value).every(isJsonValue);
}
function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function isBrowserError(error: unknown): error is PluginBrowserSessionError {
  return isRecord(error) && error.name === "PluginBrowserSessionError" && typeof error.code === "string";
}
function invalid(): never { throw new PluginManagerError("invalid_request"); }
function invalidResponse(): never { throw new PluginManagerError("plugin_invalid_response"); }

const webViewKeys = new Set<PluginWebViewKey>([
  "Enter", "Tab", "Escape", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight",
  "PageUp", "PageDown", "Home", "End", "Backspace", "Delete",
]);
