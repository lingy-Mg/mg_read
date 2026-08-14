import type {
  PluginRuntimeHttpClient,
  PluginRuntimeTraceContext,
} from "../plugin-manager.js";
import { runtimeDiagnosticValue, type RuntimeDiagnosticObjectValue } from "./contracts.js";
import { isRuntimeDiagnosticSecretField, projectRuntimeHttpUrl } from "./privacy.js";
import { runtimeDiagnosticEvents } from "./registry.js";
import type { RuntimeDiagnosticSpan } from "./manager.js";
import type { RuntimeDiagnosticsService } from "./service.js";

/** Runtime-owned `ctx.http` implementation with metadata-first diagnostics. */
export class RuntimeDiagnosticsHttpClient implements PluginRuntimeHttpClient {
  constructor(readonly #diagnostics: RuntimeDiagnosticsService) {}

  async fetch(
    input: string | URL,
    init: RequestInit,
    parent?: PluginRuntimeTraceContext,
  ): Promise<Response> {
    const startedAt = process.hrtime.bigint();
    const projection = safeProjection(input);
    const method = projectMethod(init.method);
    const requestHeaderNames = safeHeaderNames(init.headers);
    const span = this.#diagnostics.manager.startSpan({
      attributes: () => runtimeDiagnosticValue.object({
        method: runtimeDiagnosticValue.string(method),
        origin: runtimeDiagnosticValue.string(projection.origin),
        requestHeaderNames: runtimeDiagnosticValue.list(
          requestHeaderNames.map(runtimeDiagnosticValue.string),
        ),
        route: runtimeDiagnosticValue.string(projection.route),
      }),
      captureOrigin: projection.origin,
      definition: runtimeDiagnosticEvents.http,
      ...(parent === undefined ? {} : { parent }),
    });
    this.#captureReplayableRequestBody(span, input, init, projection.origin);

    try {
      const response = await fetch(input, init);
      const headersAt = process.hrtime.bigint();
      const ttfbMicros = elapsedMicros(startedAt, headersAt);
      const contentType = response.headers.get("content-type") ?? "";
      const mimeType = projectMimeType(contentType);
      const declaredBytes = parseContentLength(response.headers.get("content-length"));
      const responseHeaderNames = safeHeaderNames(response.headers);
      this.#diagnostics.manager.emit({
        attributes: () => runtimeDiagnosticValue.object({
          ...(declaredBytes === undefined
            ? {}
            : { declaredBytes: runtimeDiagnosticValue.int64(BigInt(declaredBytes)) }),
          mimeType: runtimeDiagnosticValue.string(mimeType),
          redirectCount: runtimeDiagnosticValue.int64(response.redirected ? 1n : 0n),
          responseHeaderNames: runtimeDiagnosticValue.list(
            responseHeaderNames.map(runtimeDiagnosticValue.string),
          ),
          statusCode: runtimeDiagnosticValue.int64(BigInt(response.status)),
          ttfbMicros: runtimeDiagnosticValue.int64(BigInt(ttfbMicros)),
        }),
        definition: runtimeDiagnosticEvents.httpHeaders,
        trace: span.trace,
      });

      const capture =
        span.startEventId === undefined || !isTextualMediaType(mimeType)
          ? undefined
          : this.#diagnostics.beginTextAttachment({
              captureOrigin: projection.origin,
              charset: projectCharset(contentType),
              eventId: span.startEventId,
              formatId: mimeType === "application/json" ? "json" : "text",
              kind: "http.response.body",
              mediaType: mimeType,
              privacyClass: "content",
              trace: span.trace,
            });
      if (capture === undefined || response.body === null) {
        span.end("success", {
          attributes: () => httpTerminalAttributes({
            bodyMicros: 0,
            declaredBytes,
            downloadBytes: 0,
            method,
            origin: projection.origin,
            redirectCount: response.redirected ? 1 : 0,
            route: projection.route,
            statusCode: response.status,
            ttfbMicros,
          }),
        });
        return response;
      }

      let diagnosticResponse: Response;
      try {
        diagnosticResponse = response.clone();
      } catch {
        capture.truncate("responseCloneUnavailable");
        void capture.result;
        span.end("success", {
          attributes: () => httpTerminalAttributes({
            bodyMicros: 0,
            declaredBytes,
            downloadBytes: 0,
            method,
            origin: projection.origin,
            redirectCount: response.redirected ? 1 : 0,
            route: projection.route,
            statusCode: response.status,
            ttfbMicros,
          }),
        });
        return response;
      }
      void this.#consumeDiagnosticResponse(
        diagnosticResponse,
        capture,
        span,
        {
          declaredBytes,
          headersAt,
          method,
          origin: projection.origin,
          redirectCount: response.redirected ? 1 : 0,
          route: projection.route,
          statusCode: response.status,
          ttfbMicros,
        },
      );
      return response;
    } catch (error) {
      if (!span.isEnded) {
        const cancelled = init.signal?.aborted === true || isAbortFailure(error);
        span.end(cancelled ? "cancelled" : "error", {
          attributes: () => runtimeDiagnosticValue.object({
            errorCode: runtimeDiagnosticValue.string(cancelled ? "cancelled" : "network_error"),
            method: runtimeDiagnosticValue.string(method),
            origin: runtimeDiagnosticValue.string(projection.origin),
            route: runtimeDiagnosticValue.string(projection.route),
          }),
          severity: cancelled ? "info" : "error",
        });
      }
      throw error;
    }
  }

  #captureReplayableRequestBody(
    span: RuntimeDiagnosticSpan,
    input: string | URL,
    init: RequestInit,
    origin: string,
  ): void {
    if (span.startEventId === undefined) return;
    const body = init.body;
    const bytes = typeof body === "string"
      ? Buffer.from(body, "utf8")
      : body instanceof URLSearchParams
        ? Buffer.from(body.toString(), "utf8")
        : undefined;
    if (bytes === undefined) return;
    const contentType = new Headers(init.headers).get("content-type") ?? "text/plain";
    const mimeType = projectMimeType(contentType);
    if (!isTextualMediaType(mimeType)) return;
    const capture = this.#diagnostics.beginTextAttachment({
      captureOrigin: origin,
      charset: projectCharset(contentType),
      eventId: span.startEventId,
      formatId: mimeType === "application/json" ? "json" : "text",
      kind: "http.request.body",
      mediaType: mimeType,
      privacyClass: "content",
      trace: span.trace,
    });
    if (capture === undefined) return;
    capture.offer(bytes);
    capture.finish();
    void capture.result;
    void input;
  }

  async #consumeDiagnosticResponse(
    response: Response,
    capture: NonNullable<ReturnType<RuntimeDiagnosticsService["beginTextAttachment"]>>,
    span: RuntimeDiagnosticSpan,
    context: {
      readonly declaredBytes?: number;
      readonly headersAt: bigint;
      readonly method: string;
      readonly origin: string;
      readonly redirectCount: number;
      readonly route: string;
      readonly statusCode: number;
      readonly ttfbMicros: number;
    },
  ): Promise<void> {
    let downloadBytes = 0;
    try {
      const reader = response.body?.getReader();
      if (reader !== undefined) {
        while (true) {
          const result = await reader.read();
          if (result.done) break;
          downloadBytes += result.value.byteLength;
          if (!capture.offer(result.value)) {
            await reader.cancel("diagnostic spool pressure").catch(() => undefined);
            break;
          }
        }
      }
      capture.finish();
      await capture.result;
      if (!span.isEnded) {
        span.end("success", {
          attributes: () => httpTerminalAttributes({
            ...context,
            bodyMicros: elapsedMicros(context.headersAt, process.hrtime.bigint()),
            downloadBytes,
          }),
        });
      }
    } catch {
      capture.truncate("captureReadFailed");
      await capture.result.catch(() => undefined);
      if (!span.isEnded) {
        span.end("success", {
          attributes: () => httpTerminalAttributes({
            ...context,
            bodyMicros: elapsedMicros(context.headersAt, process.hrtime.bigint()),
            downloadBytes,
          }),
          severity: "warn",
        });
      }
    }
  }
}

function httpTerminalAttributes(value: {
  readonly bodyMicros: number;
  readonly declaredBytes?: number;
  readonly downloadBytes: number;
  readonly method: string;
  readonly origin: string;
  readonly redirectCount: number;
  readonly route: string;
  readonly statusCode: number;
  readonly ttfbMicros: number;
}): RuntimeDiagnosticObjectValue {
  return runtimeDiagnosticValue.object({
    bodyMicros: runtimeDiagnosticValue.int64(BigInt(value.bodyMicros)),
    ...(value.declaredBytes === undefined
      ? {}
      : { declaredBytes: runtimeDiagnosticValue.int64(BigInt(value.declaredBytes)) }),
    downloadBytes: runtimeDiagnosticValue.int64(BigInt(value.downloadBytes)),
    method: runtimeDiagnosticValue.string(value.method),
    origin: runtimeDiagnosticValue.string(value.origin),
    redirectCount: runtimeDiagnosticValue.int64(BigInt(value.redirectCount)),
    route: runtimeDiagnosticValue.string(value.route),
    statusCode: runtimeDiagnosticValue.int64(BigInt(value.statusCode)),
    ttfbMicros: runtimeDiagnosticValue.int64(BigInt(value.ttfbMicros)),
  });
}

function safeProjection(input: string | URL): { readonly origin: string; readonly route: string } {
  try {
    const projection = projectRuntimeHttpUrl(input);
    return { origin: projection.origin, route: projection.route };
  } catch {
    return { origin: "invalid", route: "/invalid" };
  }
}

function safeHeaderNames(headers: HeadersInit | Headers | undefined): readonly string[] {
  if (headers === undefined) return Object.freeze([]);
  try {
    const names = [...new Headers(headers).keys()]
      .map((name) => name.toLowerCase())
      .filter((name) => !isRuntimeDiagnosticSecretField(name))
      .sort()
      .slice(0, 64);
    return Object.freeze([...new Set(names)]);
  } catch {
    return Object.freeze([]);
  }
}

function projectMethod(value: string | undefined): string {
  const method = (value ?? "GET").toUpperCase();
  return /^[A-Z]{1,16}$/.test(method) ? method : "OTHER";
}

function projectMimeType(contentType: string): string {
  const mimeType = contentType.split(";", 1)[0]?.trim().toLowerCase() ?? "";
  return /^[a-z0-9!#$&^_.+-]+\/[a-z0-9!#$&^_.+-]+$/.test(mimeType)
    ? mimeType
    : "application/octet-stream";
}

function projectCharset(contentType: string): string | undefined {
  const match = /(?:^|;)\s*charset=([A-Za-z0-9._-]{1,40})/i.exec(contentType);
  return match?.[1]?.toLowerCase();
}

function isTextualMediaType(mimeType: string): boolean {
  return mimeType.startsWith("text/") ||
    mimeType === "application/json" ||
    mimeType.endsWith("+json") ||
    mimeType === "application/xml" ||
    mimeType.endsWith("+xml") ||
    mimeType === "application/x-www-form-urlencoded" ||
    mimeType === "application/javascript";
}

function parseContentLength(value: string | null): number | undefined {
  if (value === null || !/^(?:0|[1-9][0-9]*)$/.test(value)) return undefined;
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) ? parsed : undefined;
}

function elapsedMicros(start: bigint, end: bigint): number {
  return Number((end - start) / 1_000n);
}

function isAbortFailure(error: unknown): boolean {
  return error instanceof DOMException && error.name === "AbortError";
}
