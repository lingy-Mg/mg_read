/**
 * Runtime source-resource URL payload codec.
 *
 * The payload is intentionally plain, reversible Base64URL JSON. It carries
 * the complete validated upstream request so resource URLs do not depend on a
 * process-local token table. Base64URL only makes JSON path-safe; it provides
 * no confidentiality or authenticity.
 */
import type { JsonObject } from "./protocol.js";

const TOKEN_VERSION = 1;
const MAX_TOKEN_CHARACTERS = 24 * 1024;

export interface SourceResourceTokenPayload {
  readonly pluginId: string;
  readonly request: JsonObject;
}

/** Encodes one source request into a self-contained loopback path segment. */
export function encodeSourceResourceToken(
  pluginId: string,
  request: JsonObject,
): string {
  return Buffer.from(JSON.stringify({
    pluginId,
    request,
    version: TOKEN_VERSION,
  }), "utf8").toString("base64url");
}

/** Decodes and validates a self-contained loopback path segment. */
export function decodeSourceResourceToken(
  token: string,
): SourceResourceTokenPayload | undefined {
  if (
    token.length < 16 ||
    token.length > MAX_TOKEN_CHARACTERS ||
    !/^[A-Za-z0-9_-]+$/u.test(token)
  ) return undefined;
  let bytes: Buffer;
  try {
    bytes = Buffer.from(token, "base64url");
  } catch {
    return undefined;
  }
  if (bytes.toString("base64url") !== token) return undefined;
  let decoded: unknown;
  try {
    decoded = JSON.parse(bytes.toString("utf8"));
  } catch {
    return undefined;
  }
  if (!isRecord(decoded) || decoded.version !== TOKEN_VERSION) return undefined;
  if (!isPluginId(decoded.pluginId) || !isJsonObject(decoded.request)) return undefined;
  return Object.freeze({ pluginId: decoded.pluginId, request: decoded.request });
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function isJsonObject(value: unknown): value is JsonObject {
  return isRecord(value);
}

function isPluginId(value: unknown): value is string {
  return typeof value === "string" && /^[a-z0-9][a-z0-9.-]{0,127}$/u.test(value);
}
