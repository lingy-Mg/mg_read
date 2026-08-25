/**
 * Runtime 私有 loopback 资源响应。
 *
 * 职责：
 * - 消费由 PluginManager 签发的短期资源与插件传输 token；
 * - 仅向 Runtime 内部 HTTP listener 写入 no-store 响应。
 *
 * 注意：
 * - 本模块不创建 listener，也不处理外部 Debug HTTP 请求；
 * - token 校验和资源所有权始终由 PluginManager 保持。
 */
import type { ServerResponse } from "node:http";

import type { PluginManager } from "./plugin-manager.js";

export type LoopbackHttpFinish = (status: number, downloadedBytes?: number) => void;

export async function serveSourceResource(
  pluginManager: PluginManager | undefined,
  token: string,
  response: ServerResponse,
  finish: LoopbackHttpFinish,
): Promise<void> {
  try {
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
      "Content-Type": "application/octet-stream", "X-MgRead-Sha256": resource.sha256,
    });
    resource.stream.on("error", () => { response.destroy(); finish(500); });
    resource.stream.pipe(response).on("finish", () => finish(200, resource.bytes));
  } catch {
    response.destroy(); finish(500);
  }
}
