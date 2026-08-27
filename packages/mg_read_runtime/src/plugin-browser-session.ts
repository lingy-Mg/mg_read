/**
 * Runtime-owned browser session capability for protected source requests.
 *
 * Responsibilities:
 * - validate the versioned plugin request before it reaches a platform host;
 * - keep Cookie and user-agent ownership inside the host browser provider;
 * - preserve invocation cancellation/deadline and map host failures to stable errors.
 *
 * Notes:
 * - this file does not launch a browser or persist browser state;
 * - platform providers must isolate sessions by plugin ID, session key and origin.
 */
import { Buffer } from "node:buffer";

import { PluginManagerError } from "./plugin-manager-contract.js";

export const maximumBrowserRequestBytes = 64 * 1024;
export const maximumBrowserResponseBytes = 2 * 1024 * 1024;
export const maximumBrowserTimeoutMs = 120_000;

export type PluginBrowserVerificationState =
  | "not-required"
  | "required"
  | "pending"
  | "verified"
  | "failed";

export interface PluginBrowserSessionRequest {
  readonly body: string | null;
  readonly headers: Readonly<Record<string, string>>;
  readonly interaction: "allow" | "silent";
  readonly maxResponseBytes: number;
  readonly method: "GET" | "POST";
  readonly presentation: "hidden" | "visible";
  readonly sessionKey: string;
  readonly timeoutMs: number;
  readonly transport: "http" | "webview";
  readonly url: string;
  readonly version: 1;
}

export interface PluginBrowserSessionResponse {
  readonly body: string;
  readonly finalUrl: string;
  readonly headers: Readonly<Record<string, string>>;
  readonly status: number;
  readonly verificationState: PluginBrowserVerificationState;
  readonly version: 1;
}

export interface PluginBrowserHostRequest extends PluginBrowserSessionRequest {
  readonly pluginId: string;
  readonly signal: AbortSignal;
}

export interface PluginBrowserSessionProvider {
  request(request: PluginBrowserHostRequest): Promise<PluginBrowserSessionResponse>;
}

export class PluginBrowserSessionError extends Error {
  constructor(
    readonly code:
      | "cancelled"
      | "interaction_required"
      | "overloaded"
      | "plugin_execution_failed"
      | "timeout"
      | "unsupported",
  ) {
    super("The host browser session could not complete the request.");
    this.name = "PluginBrowserSessionError";
  }
}

export async function requestPluginBrowserSession(
  provider: PluginBrowserSessionProvider | undefined,
  pluginId: string,
  request: unknown,
  invocationSignal: AbortSignal,
  deadlineUnixMs: string,
): Promise<PluginBrowserSessionResponse> {
  if (provider === undefined) throw new PluginManagerError("unsupported");
  const validated = validateRequest(request);
  const remainingMs = Number(deadlineUnixMs) - Date.now();
  if (invocationSignal.aborted) throw new PluginManagerError("cancelled");
  if (!Number.isFinite(remainingMs) || remainingMs <= 0) {
    throw new PluginManagerError("timeout");
  }
  const timeoutSignal = AbortSignal.timeout(
    Math.max(1, Math.min(validated.timeoutMs, remainingMs)),
  );
  const signal = AbortSignal.any([invocationSignal, timeoutSignal]);
  try {
    const response = await provider.request(Object.freeze({
      ...validated,
      pluginId,
      signal,
    }));
    return validateResponse(response, validated);
  } catch (error) {
    if (error instanceof PluginManagerError) throw error;
    if (error instanceof PluginBrowserSessionError) {
      throw new PluginManagerError(error.code);
    }
    if (signal.aborted) {
      throw new PluginManagerError(invocationSignal.aborted ? "cancelled" : "timeout");
    }
    throw new PluginManagerError("plugin_execution_failed");
  }
}

function validateRequest(value: unknown): PluginBrowserSessionRequest {
  if (!isRecord(value) || encodedBytes(value) > maximumBrowserRequestBytes) invalid();
  if (value.version !== 1 || !/^[A-Za-z0-9._-]{1,64}$/u.test(value.sessionKey as string)) invalid();
  if (value.method !== "GET" && value.method !== "POST") invalid();
  if (value.interaction !== "allow" && value.interaction !== "silent") invalid();
  if (value.presentation !== "hidden" && value.presentation !== "visible") invalid();
  if (value.transport !== "http" && value.transport !== "webview") invalid();
  const timeoutMs = boundedInteger(value.timeoutMs, 1_000, maximumBrowserTimeoutMs);
  const maxResponseBytes = boundedInteger(value.maxResponseBytes, 1, maximumBrowserResponseBytes);
  if (value.body !== null && typeof value.body !== "string") invalid();
  if (value.method === "GET" && value.body !== null) invalid();
  const url = secureUrl(value.url);
  const headers = validateHeaders(value.headers, url);
  return Object.freeze({
    body: value.body as string | null,
    headers,
    interaction: value.interaction,
    maxResponseBytes,
    method: value.method,
    presentation: value.presentation,
    sessionKey: value.sessionKey as string,
    timeoutMs,
    transport: value.transport,
    url: url.toString(),
    version: 1,
  });
}

function validateResponse(
  value: unknown,
  request: PluginBrowserSessionRequest,
): PluginBrowserSessionResponse {
  if (!isRecord(value) || value.version !== 1) invalidResponse();
  if (!Number.isInteger(value.status) || (value.status as number) < 100 || (value.status as number) > 599) invalidResponse();
  if (typeof value.body !== "string" || Buffer.byteLength(value.body, "utf8") > request.maxResponseBytes) {
    throw new PluginManagerError("overloaded");
  }
  const requestUrl = new URL(request.url);
  let finalUrl: URL;
  try { finalUrl = secureUrl(value.finalUrl); } catch { invalidResponse(); }
  if (finalUrl.origin !== requestUrl.origin) invalidResponse();
  if (!verificationStates.has(value.verificationState as PluginBrowserVerificationState)) invalidResponse();
  const headers = validateResponseHeaders(value.headers);
  return Object.freeze({
    body: value.body,
    finalUrl: finalUrl.toString(),
    headers,
    status: value.status as number,
    verificationState: value.verificationState as PluginBrowserVerificationState,
    version: 1,
  });
}

const requestHeaderNames = new Set(["accept", "accept-language", "content-type", "origin", "referer"]);
const responseHeaderNames = new Set(["cache-control", "content-type", "etag", "expires", "last-modified"]);
const verificationStates = new Set<PluginBrowserVerificationState>([
  "not-required", "required", "pending", "verified", "failed",
]);

function validateHeaders(value: unknown, url: URL): Readonly<Record<string, string>> {
  if (!isRecord(value) || Object.keys(value).length > 16) invalid();
  const result: Record<string, string> = {};
  for (const [name, header] of Object.entries(value)) {
    const normalized = name.toLowerCase();
    if (!requestHeaderNames.has(normalized) || typeof header !== "string" || header.length > 1024) invalid();
    if (normalized === "origin" || normalized === "referer") {
      try { if (new URL(header, url).origin !== url.origin) invalid(); } catch { invalid(); }
    }
    result[normalized] = header;
  }
  return Object.freeze(result);
}

function validateResponseHeaders(value: unknown): Readonly<Record<string, string>> {
  if (!isRecord(value) || Object.keys(value).length > 16) invalidResponse();
  const result: Record<string, string> = {};
  for (const [name, header] of Object.entries(value)) {
    const normalized = name.toLowerCase();
    if (!responseHeaderNames.has(normalized) || typeof header !== "string" || header.length > 1024) invalidResponse();
    result[normalized] = header;
  }
  return Object.freeze(result);
}

function secureUrl(value: unknown): URL {
  if (typeof value !== "string" || value.length > 4096) invalid();
  try {
    const url = new URL(value);
    if (url.protocol !== "https:" || url.username !== "" || url.password !== "") invalid();
    return url;
  } catch {
    invalid();
  }
}

function boundedInteger(value: unknown, minimum: number, maximum: number): number {
  if (!Number.isSafeInteger(value) || (value as number) < minimum || (value as number) > maximum) invalid();
  return value as number;
}

function encodedBytes(value: unknown): number {
  try { return Buffer.byteLength(JSON.stringify(value), "utf8"); } catch { invalid(); }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function invalid(): never { throw new PluginManagerError("invalid_request"); }
function invalidResponse(): never { throw new PluginManagerError("plugin_invalid_response"); }
