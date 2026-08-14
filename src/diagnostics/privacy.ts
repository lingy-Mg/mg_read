import { createHash } from "node:crypto";

const secretField = /(?:authorization|proxy-authorization|cookie|set-cookie|token|api[-_]?key|client[-_]?secret|credential|password|passwd|secret)/i;
const secretHeader = /^(\s*(?:authorization|proxy-authorization|cookie|set-cookie|token|api[-_]?key|client[-_]?secret|credential|password|passwd|secret)\s*:\s*).*$/gim;
const secretAssignment = /((?:authorization|proxy-authorization|cookie|set-cookie|token|api[-_]?key|client[-_]?secret|credential|password|passwd|secret)\s*["']?\s*[:=]\s*)(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[^\s,;&}\]]+)/gi;
const bearerValue = /\bBearer\s+[A-Za-z0-9._~+\/-]{4,}={0,2}/gi;
const queryValue = /([?&][A-Za-z0-9_.-]+)=([^&#\s]*)/g;
const windowsPath = /\b[A-Za-z]:\\(?:[^\s<>:"|?*]+\\)*[^\s<>:"|?*]*/g;
const unixHomePath = /\/(?:Users|home)\/[^/\s]+(?:\/[^\s]*)?/g;

export interface RuntimeHttpRouteProjection {
  readonly origin: string;
  readonly queryKeys: readonly string[];
  readonly route: string;
}

/** Projects a URL without query values, credentials, fragments, or raw IDs. */
export function projectRuntimeHttpUrl(value: URL | string): RuntimeHttpRouteProjection {
  const url = value instanceof URL ? value : new URL(value);
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new TypeError("Only HTTP(S) URLs have a Runtime HTTP projection.");
  }
  const origin = `${url.protocol}//${url.hostname.toLowerCase()}${
    url.port.length === 0 ? "" : `:${url.port}`
  }`;
  const queryKeys = [...new Set([...url.searchParams.keys()])]
    .filter((key) => !secretField.test(key))
    .sort()
    .slice(0, 32);
  const segments = url.pathname
    .split("/")
    .filter((segment) => segment.length > 0)
    .slice(0, 32)
    .map(projectRouteSegment);
  return Object.freeze({
    origin,
    queryKeys: Object.freeze(queryKeys),
    route: `/${segments.join("/")}`,
  });
}

/** Returns a stable fingerprint without retaining a raw error or stack. */
export function fingerprintRuntimeStack(value: unknown): string {
  const source = value instanceof Error ? value.stack ?? value.name : typeof value;
  const normalized = redactRuntimeDiagnosticText(source)
    .replace(/\bline \d+\b/gi, "line")
    .replace(/:\d+:\d+/g, ":#:#")
    .slice(0, 16 * 1024);
  return createHash("sha256").update(normalized, "utf8").digest("hex");
}

/** Defense-in-depth sanitizer for reviewed short text and textual attachments. */
export function redactRuntimeDiagnosticText(value: string): string {
  return value
    .replace(secretHeader, "$1<redacted>")
    .replace(secretAssignment, "$1<redacted>")
    .replace(bearerValue, "Bearer <redacted>")
    .replace(queryValue, "$1=<redacted>")
    .replace(windowsPath, "<path>")
    .replace(unixHomePath, "<path>");
}

/** Secret-like keys are never serialized, even during explicit capture. */
export function isRuntimeDiagnosticSecretField(key: string): boolean {
  return secretField.test(key);
}

/** Used by canary tests and export verification. */
export function containsForbiddenRuntimeDiagnosticText(
  value: string | Uint8Array,
  canaries: readonly string[] = [],
): boolean {
  const text = typeof value === "string" ? value : new TextDecoder().decode(value);
  if (canaries.some((canary) => canary.length > 0 && text.includes(canary))) {
    return true;
  }
  const normalized = text.replace(
    /((?:authorization|cookie|token|credential|password|secret)"?\s*:\s*)\{"kind":"redacted"[^}]*\}/gi,
    '$1"<redacted>"',
  );
  if (/\bBearer\s+(?!<redacted>)[A-Za-z0-9._~+\/-]{8,}/i.test(normalized)) {
    return true;
  }
  for (const match of normalized.matchAll(new RegExp(secretAssignment.source, "gi"))) {
    if (!match[0].includes("<redacted>")) return true;
  }
  return false;
}

export interface RuntimeDiagnosticTreeLimits {
  readonly maxArrayItems: number;
  readonly maxDepth: number;
  readonly maxEncodedBytes: number;
  readonly maxNodes: number;
  readonly maxObjectKeys: number;
  readonly maxStringCodeUnits: number;
}

export const defaultRuntimeDiagnosticTreeLimits = Object.freeze({
  maxArrayItems: 1_024,
  maxDepth: 32,
  maxEncodedBytes: 16 * 1024 * 1024,
  maxNodes: 100_000,
  maxObjectKeys: 1_024,
  maxStringCodeUnits: 64 * 1024,
} satisfies RuntimeDiagnosticTreeLimits);

export type RuntimeDiagnosticTreeNode =
  | { readonly kind: "scalar"; readonly value: boolean | null | number | string }
  | { readonly kind: "dateTime"; readonly value: string }
  | { readonly kind: "int64"; readonly value: string }
  | { readonly kind: "nonFinite"; readonly value: "NaN" | "Infinity" | "-Infinity" }
  | { readonly kind: "object"; readonly nodeId: string; readonly entries: Readonly<Record<string, RuntimeDiagnosticTreeNode>> }
  | { readonly kind: "list"; readonly nodeId: string; readonly items: readonly RuntimeDiagnosticTreeNode[] }
  | { readonly kind: "ref"; readonly nodeId: string }
  | { readonly kind: "redacted"; readonly reason: string }
  | { readonly kind: "truncated"; readonly reason: string; readonly originalCount?: number }
  | { readonly kind: "unsupported"; readonly typeName: string };

export interface RuntimeDiagnosticTreeDocument {
  readonly formatId: "mgread.diagnostic-tree";
  readonly formatVersion: 1;
  readonly redactionVersion: 1;
  readonly root: RuntimeDiagnosticTreeNode;
  readonly truncated: boolean;
}

/**
 * Serializes an arbitrary internal graph without calling getters, iterators or
 * custom toJSON methods. Cycles and shared references become explicit refs.
 */
export function serializeRuntimeDiagnosticTree(
  value: unknown,
  limits: RuntimeDiagnosticTreeLimits = defaultRuntimeDiagnosticTreeLimits,
): Uint8Array {
  validateTreeLimits(limits);
  const references = new WeakMap<object, string>();
  let nextNodeId = 0;
  let nodeCount = 0;
  let truncated = false;

  const truncate = (reason: string, originalCount?: number): RuntimeDiagnosticTreeNode => {
    truncated = true;
    return Object.freeze({
      kind: "truncated",
      ...(originalCount === undefined ? {} : { originalCount }),
      reason,
    });
  };

  const visit = (current: unknown, depth: number): RuntimeDiagnosticTreeNode => {
    nodeCount += 1;
    if (nodeCount > limits.maxNodes) return truncate("nodeLimit");
    if (depth > limits.maxDepth) return truncate("depthLimit");
    if (current === null || typeof current === "boolean") {
      return Object.freeze({ kind: "scalar", value: current });
    }
    if (typeof current === "string") {
      if (current.length > limits.maxStringCodeUnits) {
        return truncate("stringLimit", current.length);
      }
      return Object.freeze({ kind: "scalar", value: redactRuntimeDiagnosticText(current) });
    }
    if (typeof current === "number") {
      if (Number.isFinite(current)) return Object.freeze({ kind: "scalar", value: current });
      return Object.freeze({
        kind: "nonFinite",
        value: Number.isNaN(current) ? "NaN" : current > 0 ? "Infinity" : "-Infinity",
      });
    }
    if (typeof current === "bigint") {
      return Object.freeze({ kind: "int64", value: current.toString(10) });
    }
    if (current instanceof Date) {
      const millis = current.getTime();
      return Number.isFinite(millis)
        ? Object.freeze({ kind: "dateTime", value: current.toISOString() })
        : Object.freeze({ kind: "unsupported", typeName: "InvalidDate" });
    }
    if ((typeof current !== "object" || current === null) && typeof current !== "function") {
      return Object.freeze({ kind: "unsupported", typeName: typeof current });
    }
    if (typeof current === "function") {
      return Object.freeze({ kind: "unsupported", typeName: "function" });
    }

    const prior = references.get(current);
    if (prior !== undefined) return Object.freeze({ kind: "ref", nodeId: prior });
    nextNodeId += 1;
    const nodeId = `node-${nextNodeId.toString(36)}`;
    references.set(current, nodeId);

    if (Array.isArray(current)) {
      const count = Math.min(current.length, limits.maxArrayItems);
      const items: RuntimeDiagnosticTreeNode[] = [];
      for (let index = 0; index < count; index += 1) {
        const descriptor = Object.getOwnPropertyDescriptor(current, index.toString());
        items.push(
          descriptor !== undefined && "value" in descriptor
            ? visit(descriptor.value, depth + 1)
            : Object.freeze({ kind: "unsupported", typeName: "accessor" }),
        );
      }
      if (current.length > count) items.push(truncate("arrayLimit", current.length));
      return Object.freeze({ items: Object.freeze(items), kind: "list", nodeId });
    }

    const descriptors = Object.getOwnPropertyDescriptors(current);
    const keys = Object.keys(descriptors).sort();
    const count = Math.min(keys.length, limits.maxObjectKeys);
    const entries: Record<string, RuntimeDiagnosticTreeNode> = {};
    for (let index = 0; index < count; index += 1) {
      const key = keys[index];
      if (key === undefined) continue;
      if (isRuntimeDiagnosticSecretField(key)) {
        entries[key] = Object.freeze({ kind: "redacted", reason: "secretField" });
        continue;
      }
      const descriptor = descriptors[key];
      entries[key] = descriptor !== undefined && "value" in descriptor
        ? visit(descriptor.value, depth + 1)
        : Object.freeze({ kind: "unsupported", typeName: "accessor" });
    }
    if (keys.length > count) {
      entries.$truncated = truncate("objectKeyLimit", keys.length);
    }
    return Object.freeze({ entries: Object.freeze(entries), kind: "object", nodeId });
  };

  let document: RuntimeDiagnosticTreeDocument = Object.freeze({
    formatId: "mgread.diagnostic-tree",
    formatVersion: 1,
    redactionVersion: 1,
    root: visit(value, 0),
    truncated,
  });
  let encoded = new TextEncoder().encode(JSON.stringify(document));
  if (encoded.byteLength > limits.maxEncodedBytes) {
    document = Object.freeze({
      ...document,
      root: Object.freeze({ kind: "truncated", reason: "encodedByteLimit" }),
      truncated: true,
    });
    encoded = new TextEncoder().encode(JSON.stringify(document));
  }
  return encoded;
}

/** Parses JSON, recursively redacts secret keys, and serializes a safe tree. */
export function sanitizeRuntimeStructuredJson(
  bytes: Uint8Array,
  limits: RuntimeDiagnosticTreeLimits = defaultRuntimeDiagnosticTreeLimits,
): Uint8Array {
  if (bytes.byteLength > limits.maxEncodedBytes) {
    throw new RangeError("Structured diagnostic JSON exceeds the byte limit.");
  }
  const decoded = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  return serializeRuntimeDiagnosticTree(JSON.parse(decoded) as unknown, limits);
}

function projectRouteSegment(segment: string): string {
  const decoded = safeDecodeURIComponent(segment);
  if (
    decoded.length > 64 ||
    /^[0-9]+$/.test(decoded) ||
    /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(decoded) ||
    /^[A-Za-z0-9_-]{24,}$/.test(decoded)
  ) {
    return ":id";
  }
  return decoded.replace(/[^A-Za-z0-9._~-]/g, "_");
}

function safeDecodeURIComponent(value: string): string {
  try {
    return decodeURIComponent(value);
  } catch {
    return "invalid-segment";
  }
}

function validateTreeLimits(limits: RuntimeDiagnosticTreeLimits): void {
  for (const value of Object.values(limits)) {
    if (!Number.isSafeInteger(value) || value <= 0) {
      throw new RangeError("Diagnostic tree limits must be positive integers.");
    }
  }
}
