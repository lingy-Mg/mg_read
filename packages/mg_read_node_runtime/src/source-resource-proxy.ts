/** Runtime data-plane source resource proxy. Plugin code never sees a body. */
import { createDecipheriv } from "node:crypto";

import type { JsonObject } from "./protocol.js";
import type { PluginRuntimeHttpClient } from "./plugin-manager-contract.js";

export type SourceProxyEntry = {
  readonly fetch: PluginRuntimeHttpClient["fetch"];
  readonly proxy: (request: JsonObject) => string;
  readonly request: JsonObject;
};

export type SourceProxyResource = {
  readonly onServed?: (status: number, bytes: number, durationMs: number) => void;
  readonly proxy: SourceProxyEntry["proxy"];
  readonly request: JsonObject;
  readonly response: Response;
  readonly responseUrl: string;
};

/** Opens a Manager-owned source resource without duplicating its token registry. */
export async function openSourceProxyResource(
  entry: SourceProxyEntry | undefined,
  requestHeaders: Readonly<Record<string, string>>,
  signal: AbortSignal,
): Promise<SourceProxyResource | undefined> {
  if (entry === undefined || signal.aborted) return undefined;
  const rawUrl = entry.request.url;
  if (typeof entry.request.kind !== "string" || typeof rawUrl !== "string" || !isHttpUrl(rawUrl)) return undefined;
  const forwarded = sourceHeaders(entry.request);
  if (forwarded === undefined) return undefined;
  if (entry.request.resourceTransform === "aes-cbc-split-image-v1") {
    return openAesCbcSplitImage(entry, forwarded, signal);
  }
  if (entry.request.resourceTransform !== undefined) return undefined;
  if (entry.request.resourceRole !== "hlsKey") {
    for (const name of ["range", "if-range"]) {
      const value = requestHeaders[name];
      if (value !== undefined && value.length <= 512) forwarded[name] = value;
    }
  }
  const proxyMode = entry.request.proxyMode === "direct" ? "direct" : undefined;
  const response = await entry.fetch(rawUrl, { headers: forwarded, method: "GET", redirect: "follow", signal }, undefined, proxyMode);
  return Object.freeze({ proxy: entry.proxy, request: entry.request, response, responseUrl: response.url });
}

async function openAesCbcSplitImage(
  entry: SourceProxyEntry,
  headers: Readonly<Record<string, string>>,
  signal: AbortSignal,
): Promise<SourceProxyResource | undefined> {
  const urls = imagePartUrls(entry.request.urls);
  const firstUrl = urls?.[0];
  if (urls === undefined || firstUrl === undefined) return undefined;
  const proxyMode = entry.request.proxyMode === "direct" ? "direct" : undefined;
  const parts = await Promise.all(urls.map((url) => entry.fetch(
    url,
    { headers, method: "GET", redirect: "follow", signal },
    undefined,
    proxyMode,
  )));
  if (parts.some((part) => !part.ok)) throw new Error("source image part request failed");
  const decrypted = await Promise.all(parts.map(async (part) => {
    const body = Buffer.from(await part.arrayBuffer());
    const decipher = createDecipheriv(
      "aes-128-cbc",
      Buffer.from("aaaaaaaaaaaaaaaa", "ascii"),
      Buffer.from("0123456789aaaaaa", "ascii"),
    );
    return Buffer.concat([decipher.update(body), decipher.final()]);
  }));
  const body = Buffer.concat(decrypted);
  const media = restoreImageHeader(body);
  const response = new Response(media, {
    status: 200,
    headers: {
      "cache-control": "no-store",
      "content-length": String(media.byteLength),
      "content-type": imageContentType(body[0]),
    },
  });
  return Object.freeze({ proxy: entry.proxy, request: entry.request, response, responseUrl: firstUrl });
}

function imagePartUrls(value: JsonObject["urls"] | undefined): readonly string[] | undefined {
  if (!Array.isArray(value) || value.length < 2 || value.length > 8) return undefined;
  if (!value.every((item) => typeof item === "string" && isHttpUrl(item))) return undefined;
  return value as readonly string[];
}

function restoreImageHeader(body: Buffer): Buffer {
  const type = body[0];
  if (type === 0) return Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, ...body.subarray(12)]);
  if (type === 1) return Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, ...body.subarray(8)]);
  if (type === 3) return Buffer.from([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, ...body.subarray(6)]);
  if (type === 4) return Buffer.from([0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70, 0x61, 0x76, 0x69, 0x66, ...body.subarray(12)]);
  throw new Error("source image format is invalid");
}

function imageContentType(type: number | undefined): string {
  if (type === 1) return "image/png";
  if (type === 3) return "image/gif";
  if (type === 4) return "image/avif";
  return "image/jpeg";
}

function sourceHeaders(request: JsonObject): Record<string, string> | undefined {
  const configured = request.headers;
  if (!isHeaderRecord(configured)) return undefined;
  return { ...configured };
}

function isHttpUrl(value: string): boolean {
  try { const url = new URL(value); return (url.protocol === "http:" || url.protocol === "https:") && url.username === "" && url.password === ""; }
  catch { return false; }
}

function isHeaderRecord(value: unknown): value is Readonly<Record<string, string>> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
  const values = Object.entries(value);
  return values.length <= 16 && values.every(([name, header]) => /^[A-Za-z0-9-]{1,64}$/.test(name) && typeof header === "string" && header.length <= 4096 && !/[\r\n]/.test(header));
}
