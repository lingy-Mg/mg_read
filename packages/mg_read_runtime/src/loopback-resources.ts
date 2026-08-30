/**
 * Runtime 私有 loopback 资源响应。
 *
 * 职责：
 * - 消费由 PluginManager 签发的短期资源与插件传输 token；
 * - 提供有界插件图标投影，不暴露安装路径或原始 descriptor；
 * - 仅向 Runtime 内部 HTTP listener 写入 no-store 响应。
 *
 * 注意：
 * - 本模块不创建 listener，也不处理外部 Debug HTTP 请求；
 * - token 校验和资源所有权始终由 PluginManager 保持。
 */
import { Readable } from "node:stream";
import type { IncomingMessage, ServerResponse } from "node:http";

import type { JsonObject } from "./protocol.js";
import type { PluginManager } from "./plugin-manager.js";

export type LoopbackHttpFinish = (status: number, downloadedBytes?: number) => void;

export async function serveSourceResource(
  pluginManager: PluginManager | undefined,
  token: string,
  response: ServerResponse,
  finish: LoopbackHttpFinish,
  request?: IncomingMessage,
): Promise<void> {
  try {
    const media = await pluginManager?.openMediaResource(
      token,
      request === undefined ? {} : requestHeaders(request),
      new AbortController().signal,
    );
    if (media !== undefined) {
      await serveMediaResource(media, response, finish);
      return;
    }
    const result = await pluginManager?.consumeResource(token, new AbortController().signal);
    if (result === undefined) { response.writeHead(404); response.end(); finish(404); return; }
    response.writeHead(result.status, { "Cache-Control": "no-store", ...result.headers, "Content-Length": result.body.byteLength });
    response.end(result.body); finish(result.status);
  } catch {
    response.writeHead(404); response.end(); finish(404);
  }
}

export async function servePluginTransferResource(
  pluginManager: PluginManager | undefined,
  token: string,
  response: ServerResponse,
  finish: LoopbackHttpFinish,
): Promise<void> {
  const resource = pluginManager?.consumePluginTransferResource(token);
  if (resource === undefined) { response.writeHead(404); response.end(); finish(404); return; }
  try {
    response.writeHead(200, {
      "Cache-Control": "no-store", "Content-Length": resource.bytes,
      "Content-Type": resource.format === "singleFile" ? "text/javascript; charset=utf-8" : "application/octet-stream",
      "X-MgRead-Artifact-Format": resource.format,
      "X-MgRead-Sha256": resource.sha256,
    });
    resource.stream.on("error", () => { response.destroy(); finish(500); });
    resource.stream.pipe(response).on("finish", () => finish(200, resource.bytes));
  } catch {
    response.destroy(); finish(500);
  }
}

async function serveMediaResource(
  media: { readonly request: JsonObject; readonly response: Response; readonly proxy: (request: JsonObject) => string },
  response: ServerResponse,
  finish: LoopbackHttpFinish,
): Promise<void> {
  const headers = responseHeaders(media.response.headers);
  const kind = media.request.kind;
  if (kind === "hls") {
    const text = await readManifest(media.response);
    const body = Buffer.from(rewriteHls(text, media.response.url, media.request, media.proxy), "utf8");
    response.writeHead(media.response.status, { "Cache-Control": "no-store", "Content-Length": body.byteLength, "Content-Type": "application/vnd.apple.mpegurl; charset=utf-8" });
    response.end(body); finish(media.response.status, body.byteLength); return;
  }
  if (media.response.body === null) { response.writeHead(media.response.status, { "Cache-Control": "no-store", ...headers }); response.end(); finish(media.response.status); return; }
  response.writeHead(media.response.status, { "Cache-Control": "no-store", ...headers });
  const stream = Readable.fromWeb(media.response.body as import("node:stream/web").ReadableStream);
  stream.on("error", () => { response.destroy(); finish(502); });
  stream.pipe(response).on("finish", () => finish(media.response.status));
}

function responseHeaders(headers: Headers): Record<string, string> {
  const result: Record<string, string> = {};
  for (const name of ["accept-ranges", "content-length", "content-range", "content-type", "etag", "last-modified"]) {
    const value = headers.get(name); if (value !== null) result[name] = value;
  }
  return result;
}

async function readManifest(response: Response): Promise<string> {
  const body = await response.arrayBuffer();
  if (body.byteLength > 1024 * 1024) throw new Error("manifest_too_large");
  return new TextDecoder().decode(body);
}

function rewriteHls(text: string, base: string, request: JsonObject, createProxy: (request: JsonObject) => string): string {
  const proxy = (raw: string) => createProxy({ ...request, url: new URL(raw, base).toString() });
  return text.split(/\r?\n/u).map((line) => {
    if (line === "" || line.startsWith("#") === false) return line === "" ? line : proxy(line);
    return line.replace(/URI="([^"]+)"/gu, (_whole, uri: string) => `URI="${proxy(uri)}"`);
  }).join("\n");
}

function requestHeaders(request: IncomingMessage): Record<string, string> {
  const result: Record<string, string> = {};
  for (const name of ["range", "if-range"]) {
    const value = request.headers[name];
    if (typeof value === "string") result[name] = value;
  }
  return result;
}

export async function servePluginIconResource(
  pluginManager: PluginManager | undefined,
  token: string,
  response: ServerResponse,
  finish: LoopbackHttpFinish,
): Promise<void> {
  const resource = await pluginManager?.consumePluginIconResource(token);
  if (resource === undefined) { response.writeHead(404); response.end(); finish(404); return; }
  response.writeHead(200, {
    "Cache-Control": "private, max-age=300",
    "Content-Length": resource.body.byteLength,
    "Content-Type": resource.mediaType,
  });
  response.end(resource.body);
  finish(200, resource.body.byteLength);
}
