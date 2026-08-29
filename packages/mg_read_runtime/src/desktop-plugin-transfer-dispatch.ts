/**
 * Runtime Core 的插件 artifact 传输控制处理器。
 *
 * 职责：处理局域网 artifact 列表、规划、导出、校验和 Windows Debug 开发数据源插件发布包。
 * 注意：只返回受限元数据和一次性 token；路径、代码与 artifact 字节仍由 Runtime 私有资源层持有。
 * TODO: - 无。
 */
import type { PluginManager } from "./plugin-manager.js";
import {
  PluginArtifactTransferError as PluginTransferError,
  type PluginTransferArtifact,
  MAX_PLUGIN_ARTIFACT_TRANSFER_BATCH as MAX_PLUGIN_TRANSFER_BATCH,
} from "./plugin-artifact-transfer.js";
import type {
  JsonValue,
  RuntimeErrorCode,
  RuntimeProtocolError,
  RuntimeRequest,
} from "./protocol.js";

export type PluginTransferDispatchResult =
  | { readonly error: RuntimeProtocolError }
  | { readonly result: JsonValue };

type RequestError = (
  request: RuntimeRequest,
  code: RuntimeErrorCode,
  message: string,
) => RuntimeProtocolError;

function failure(
  request: RuntimeRequest,
  error: unknown,
  requestError: RequestError,
): PluginTransferDispatchResult {
  const code = error instanceof PluginTransferError ? error.code : "internal";
  return { error: requestError(request, code as RuntimeErrorCode, "The Runtime plugin artifact transfer could not be completed.") };
}

export async function dispatchPluginTransferList(
  request: RuntimeRequest,
  manager: PluginManager | undefined,
  requestError: RequestError,
): Promise<PluginTransferDispatchResult> {
  if (Object.keys(request.params).length !== 0) return { error: requestError(request, "invalid_request", "The plugin transfer list request is invalid.") };
  try {
    if (manager === undefined) throw new PluginTransferError("plugin_not_found");
    return { result: await manager.listExportableArtifacts() };
  } catch (error) { return failure(request, error, requestError); }
}

export async function dispatchPluginTransferPlan(
  request: RuntimeRequest,
  manager: PluginManager | undefined,
  requestError: RequestError,
): Promise<PluginTransferDispatchResult> {
  const raw = request.params.artifacts;
  if (!Array.isArray(raw) || raw.length > MAX_PLUGIN_TRANSFER_BATCH || Object.keys(request.params).length !== 1) {
    return { error: requestError(request, "invalid_request", "The plugin transfer plan request is invalid.") };
  }
  try {
    if (manager === undefined) throw new PluginTransferError("plugin_not_found");
    return { result: await manager.planPluginTransfer(raw as PluginTransferArtifact[]) };
  } catch (error) { return failure(request, error, requestError); }
}

export async function dispatchPluginTransferExport(
  request: RuntimeRequest,
  manager: PluginManager | undefined,
  requestError: RequestError,
): Promise<PluginTransferDispatchResult> {
  const id = request.params.id;
  const version = request.params.version;
  if (Object.keys(request.params).length !== 2 || typeof id !== "string" || typeof version !== "string") {
    return { error: requestError(request, "invalid_request", "The plugin transfer export request is invalid.") };
  }
  try {
    if (manager === undefined) throw new PluginTransferError("plugin_not_found");
    const resource = await manager.createPluginTransferResource(id, version);
    return { result: { ...resource.artifact, token: resource.token } };
  } catch (error) { return failure(request, error, requestError); }
}

export async function dispatchPluginDevelopmentPackage(
  request: RuntimeRequest,
  manager: PluginManager | undefined,
  requestError: RequestError,
): Promise<PluginTransferDispatchResult> {
  const pluginId = request.params.pluginId;
  if (Object.keys(request.params).length !== 1 || typeof pluginId !== "string") {
    return { error: requestError(request, "invalid_request", "The development plugin package request is invalid.") };
  }
  try {
    if (manager === undefined) throw new PluginTransferError("plugin_not_found");
    const resource = await manager.createDevelopmentPackageResource(pluginId);
    return { result: { ...resource.artifact, fileName: resource.fileName, token: resource.token } };
  } catch (error) { return failure(request, error, requestError); }
}

export async function dispatchPluginTransferVerify(
  request: RuntimeRequest,
  manager: PluginManager | undefined,
  requestError: RequestError,
): Promise<PluginTransferDispatchResult> {
  const raw = request.params.artifacts;
  if (!Array.isArray(raw) || Object.keys(request.params).length !== 1) {
    return { error: requestError(request, "invalid_request", "The plugin transfer verification request is invalid.") };
  }
  try {
    if (manager === undefined) throw new PluginTransferError("plugin_not_found");
    await manager.verifyPluginTransferInbox(raw as PluginTransferArtifact[]);
    return { result: { verified: true } };
  } catch (error) { return failure(request, error, requestError); }
}
