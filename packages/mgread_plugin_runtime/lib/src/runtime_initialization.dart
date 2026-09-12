part of mgread_plugin_runtime;

/// Bounded Runtime-owned initialization phase safe for Flutter presentation.
enum RuntimeInitializationStage {
  assetsCopying,
  assetsCopied,
  assetsReused,
  nodeStarting,
  pluginCopying,
  pluginCopied,
  pluginInboxScanned,
  pluginInstalling,
  pluginUninstalling,
  pluginUninstalled,
  developmentPluginsScanned,
  installedPluginsSnapshotted,
  pendingPluginsActivated,
  serviceReady,
  ready,
}

/// Actual native initialization progress without paths, archive names or data.
@immutable
final class RuntimeInitializationProgress {
  const RuntimeInitializationProgress._({
    required this.catalogState,
    required this.completedBytes,
    required this.detail,
    required this.durationMicros,
    required this.itemCount,
    required this.stage,
    required this.totalBytes,
  });

  final String? catalogState;
  final int completedBytes;
  final String? detail;
  final int? durationMicros;
  final int? itemCount;
  final RuntimeInitializationStage stage;
  final int totalBytes;

  double? get fraction => totalBytes == 0 ? null : completedBytes / totalBytes;

  static RuntimeInitializationProgress? fromPlatform({
    String? catalogState,
    required int completedBytes,
    String? detail,
    int? durationMicros,
    int? itemCount,
    required String stage,
    required int totalBytes,
  }) {
    final resolvedStage = switch (stage) {
      'assets_copying' => RuntimeInitializationStage.assetsCopying,
      'assets_copied' => RuntimeInitializationStage.assetsCopied,
      'assets_reused' => RuntimeInitializationStage.assetsReused,
      'node_starting' => RuntimeInitializationStage.nodeStarting,
      'plugin_copying' => RuntimeInitializationStage.pluginCopying,
      'plugin_copied' => RuntimeInitializationStage.pluginCopied,
      'plugin_inbox_scanned' => RuntimeInitializationStage.pluginInboxScanned,
      'plugin_installing' => RuntimeInitializationStage.pluginInstalling,
      'plugin_uninstalling' => RuntimeInitializationStage.pluginUninstalling,
      'plugin_uninstalled' => RuntimeInitializationStage.pluginUninstalled,
      'development_plugins_scanned' =>
        RuntimeInitializationStage.developmentPluginsScanned,
      'installed_plugins_snapshotted' =>
        RuntimeInitializationStage.installedPluginsSnapshotted,
      'pending_plugins_activated' =>
        RuntimeInitializationStage.pendingPluginsActivated,
      'service_ready' => RuntimeInitializationStage.serviceReady,
      'ready' => RuntimeInitializationStage.ready,
      _ => null,
    };
    if (resolvedStage == null) return null;
    if (catalogState != null &&
        catalogState != 'hit' &&
        catalogState != 'rebuilt')
      return null;
    if (durationMicros != null && durationMicros < 0) return null;
    if (itemCount != null && itemCount < 0) return null;
    final normalizedDetail = detail?.trim();
    if (normalizedDetail != null &&
        (normalizedDetail.isEmpty ||
            normalizedDetail.length > 256 ||
            normalizedDetail.contains('\n') ||
            normalizedDetail.contains('\r'))) {
      return null;
    }
    return RuntimeInitializationProgress._(
      catalogState: catalogState,
      completedBytes: completedBytes,
      detail: normalizedDetail,
      durationMicros: durationMicros,
      itemCount: itemCount,
      stage: resolvedStage,
      totalBytes: totalBytes,
    );
  }
}
