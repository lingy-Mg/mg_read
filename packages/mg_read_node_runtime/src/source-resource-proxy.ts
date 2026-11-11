/** Runtime data-plane source resource proxy. Plugin code never sees a body. */
import { createDecipheriv } from "node:crypto";
import { contentLimits } from './content-limits.js';

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
  if (entry.request.resourceTransform === "sniff-image-content-type-v1") {
    return openSniffedImage(entry, forwarded, signal);
  }
  if (entry.request.resourceTransform === "aes-cbc-prefixed-iv-image-v1") {
    return openAesCbcPrefixedIvImage(entry, forwarded, signal);
  }
  if (entry.request.resourceTransform === "aes-cbc-encrypt-then-split-image-v1") {
    return openAesCbcEncryptThenSplitImage(entry, forwarded, signal);
  }
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

async function openSniffedImage(
  entry: SourceProxyEntry,
  headers: Readonly<Record<string, string>>,
  signal: AbortSignal,
): Promise<SourceProxyResource | undefined> {
  const rawUrl = entry.request.url;
  if (entry.request.kind !== "image" || typeof rawUrl !== "string") return undefined;
  const proxyMode = entry.request.proxyMode === "direct" ? "direct" : undefined;
  const upstream = await entry.fetch(
    rawUrl,
    { headers, method: "GET", redirect: "follow", signal },
    undefined,
    proxyMode,
  );
  if (!upstream.ok || upstream.body === null) {
    return Object.freeze({ proxy: entry.proxy, request: entry.request, response: upstream, responseUrl: upstream.url });
  }
  const reader = upstream.body.getReader();
  const first = await reader.read();
  if (first.done) {
    await reader.cancel().catch(() => {});
    throw new Error("source image format is invalid");
  }
  const contentType = detectImageContentType(Buffer.from(first.value));
  if (contentType === undefined) {
    await reader.cancel().catch(() => {});
    throw new Error("source image format is invalid");
  }
  const responseHeaders = new Headers(upstream.headers);
  responseHeaders.set("content-type", contentType);
  const response = new Response(streamWithFirstChunk(reader, first.value), {
    status: upstream.status,
    statusText: upstream.statusText,
    headers: responseHeaders,
  });
  return Object.freeze({ proxy: entry.proxy, request: entry.request, response, responseUrl: upstream.url || rawUrl });
}

function streamWithFirstChunk(
  reader: ReadableStreamDefaultReader<Uint8Array>,
  first: Uint8Array,
): ReadableStream<Uint8Array> {
  return new ReadableStream<Uint8Array>({
    start(controller) { controller.enqueue(first); },
    async pull(controller) {
      try {
        const next = await reader.read();
        if (next.done) controller.close();
        else controller.enqueue(next.value);
      } catch (error) {
        controller.error(error);
      }
    },
    async cancel(reason) { await reader.cancel(reason).catch(() => {}); },
  });
}

async function openAesCbcPrefixedIvImage(
  entry: SourceProxyEntry,
  headers: Readonly<Record<string, string>>,
  signal: AbortSignal,
): Promise<SourceProxyResource | undefined> {
  const rawUrl = entry.request.url;
  const key = aes256Key(entry.request.resourceTransformKey);
  if (typeof rawUrl !== "string" || key === undefined) return undefined;
  const proxyMode = entry.request.proxyMode === "direct" ? "direct" : undefined;
  const upstream = await entry.fetch(
    rawUrl,
    { headers, method: "GET", redirect: "follow", signal },
    undefined,
    proxyMode,
  );
  if (!upstream.ok) {
    return Object.freeze({ proxy: entry.proxy, request: entry.request, response: upstream, responseUrl: upstream.url });
  }
  const encrypted = Buffer.from(await upstream.arrayBuffer());
  let media = encrypted;
  let contentType = detectImageContentType(media);
  if (contentType === undefined) {
    if (encrypted.byteLength <= 16 || (encrypted.byteLength - 16) % 16 !== 0) {
      throw new Error("source encrypted image format is invalid");
    }
    const decipher = createDecipheriv("aes-256-cbc", key, encrypted.subarray(0, 16));
    media = Buffer.concat([decipher.update(encrypted.subarray(16)), decipher.final()]);
    contentType = detectImageContentType(media);
  }
  if (contentType === undefined) throw new Error("source decrypted image format is invalid");
  const response = new Response(media, {
    status: 200,
    headers: {
      "cache-control": "no-store",
      "content-length": String(media.byteLength),
      "content-type": contentType,
    },
  });
  return Object.freeze({ proxy: entry.proxy, request: entry.request, response, responseUrl: upstream.url || rawUrl });
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

async function openAesCbcEncryptThenSplitImage(
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
  const encrypted = Buffer.concat(await Promise.all(parts.map(async (part) => Buffer.from(await part.arrayBuffer()))));
  const decipher = createDecipheriv(
    "aes-128-cbc",
    Buffer.from("aaaaaaaaaaaaaaaa", "ascii"),
    Buffer.from("0123456789aaaaaa", "ascii"),
  );
  const body = Buffer.concat([decipher.update(encrypted), decipher.final()]);
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

function aes256Key(value: JsonObject["resourceTransformKey"] | undefined): Buffer | undefined {
  if (typeof value !== "string") return undefined;
  const key = Buffer.from(value, "utf8");
  return key.byteLength === 32 ? key : undefined;
}

function detectImageContentType(body: Buffer): string | undefined {
  if (body.subarray(0, 3).equals(Buffer.from([0xff, 0xd8, 0xff]))) return "image/jpeg";
  if (body.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return "image/png";
  if (body.subarray(0, 4).toString("ascii") === "GIF8") return "image/gif";
  if (body.subarray(0, 4).toString("ascii") === "RIFF" && body.subarray(8, 12).toString("ascii") === "WEBP") return "image/webp";
  if (body.subarray(4, 8).toString("ascii") === "ftyp") return "image/avif";
  return undefined;
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
  return values.length <= 16 && values.every(([name, header]) => /^[A-Za-z0-9-]{1,64}$/.test(name) && typeof header === "string" && header.length <= contentLimits.headerValueCharacters && !/[\r\n]/.test(header));
}
