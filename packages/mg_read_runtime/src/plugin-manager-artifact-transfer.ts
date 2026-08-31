/**
 * 插件管理器的 artifact 投影与开发发布包协调。
 *
 * 职责：把已加载 development 项目投影为受限 artifact 构建输入，并生成声明版本的本地发布包资源。
 * 注意：本模块不读写工作区，也不暴露路径；artifact 数据继续停留在 Runtime 私有传输管理器。
 */
import {
  PluginArtifactTransferManager,
  type DevelopmentTransferProject,
  type PluginTransferArtifact,
  type PluginTransferOffer,
} from "./plugin-artifact-transfer.js";
import {
  type DevelopmentPlugin,
  type InstalledPluginSnapshot,
} from "./plugin-manager-contract.js";

export function listExportablePluginArtifacts(
  transfer: PluginArtifactTransferManager,
  installed: readonly InstalledPluginSnapshot[],
  development: Iterable<DevelopmentPlugin>,
): Promise<readonly PluginTransferArtifact[]> {
  return transfer.listExportable(
    installed,
    [...development].map(toDevelopmentTransferProject),
  );
}

export function listPluginTransferOffers(
  transfer: PluginArtifactTransferManager,
  installed: readonly InstalledPluginSnapshot[],
  development: Iterable<DevelopmentPlugin>,
): Promise<readonly PluginTransferOffer[]> {
  return transfer.listOffers(
    installed,
    [...development].map(toDevelopmentTransferProject),
  );
}

export function toDevelopmentTransferProject(
  plugin: DevelopmentPlugin,
): DevelopmentTransferProject {
  return {
    fingerprint: plugin.fingerprint,
    id: plugin.loaded.descriptor.id,
    packageMode: plugin.loaded.descriptor.packageMode,
    projectRoot: plugin.projectRoot,
    syncRevision: plugin.syncRevision,
    version: plugin.loaded.descriptor.version,
  };
}

export async function createDevelopmentPackageArtifactResource(
  transfer: PluginArtifactTransferManager,
  development: DevelopmentPlugin,
): Promise<{
  readonly artifact: PluginTransferArtifact;
  readonly fileName: string;
  readonly token: string;
}> {
  const resource = await transfer.createDevelopmentPackageResource(
    toDevelopmentTransferProject(development),
  );
  const suffix = resource.artifact.format === "singleFile" ? ".mgplugin.js" : ".mgplugin";
  return Object.freeze({
    ...resource,
    fileName: `${resource.artifact.id}-${resource.artifact.version}${suffix}`,
  });
}
