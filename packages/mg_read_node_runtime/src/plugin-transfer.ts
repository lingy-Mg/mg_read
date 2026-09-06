/**
 * Runtime 插件 artifact v2 传输公开 Core 入口。
 *
 * 职责：稳定导出双格式传输管理器、wire 类型和校验函数。
 * 注意：v1 缺少 format 的 archive-shaped item 会稳定按 invalid_request 拒绝；
 * 插件数量不设上限，但仍受单个 artifact 和总字节上限约束。
 */
export {
  MAX_PLUGIN_ARTIFACT_TRANSFER_BATCH_BYTES as MAX_PLUGIN_TRANSFER_BATCH_BYTES,
  PluginArtifactTransferError as PluginTransferError,
  PluginArtifactTransferManager as PluginTransferManager,
  isPluginTransferArtifact,
  validateArtifactBatch as validateBatch,
} from "./plugin-artifact-transfer.js";
export { MAX_PLUGIN_ARTIFACT_BYTES as MAX_PLUGIN_TRANSFER_BYTES } from "./plugin-single-file.js";
export type {
  DevelopmentTransferProject,
  PluginTransferArtifact,
  PluginTransferPlanItem,
  PluginTransferResource,
} from "./plugin-artifact-transfer.js";
