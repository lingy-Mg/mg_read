part of mgread_plugin_runtime;

/// Bounded Runtime-owned initialization phase safe for Flutter presentation.
enum RuntimeInitializationStage {
  assetsCopying,
  assetsCopied,
  assetsReused,
  nodeStarting,
  pluginCopying,
  pluginCopied,
  pluginInstalling,
  ready,
}

/// Actual native initialization progress without paths, archive names or data.
@immutable
final class RuntimeInitializationProgress {
  const RuntimeInitializationProgress._({
    required this.completedBytes,
    required this.detail,
    required this.stage,
    required this.totalBytes,
  });

  final int completedBytes;
  final String? detail;
  final RuntimeInitializationStage stage;
  final int totalBytes;

  double? get fraction => totalBytes == 0 ? null : completedBytes / totalBytes;

  static RuntimeInitializationProgress? fromPlatform({
    required int completedBytes,
    String? detail,
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
      'plugin_installing' => RuntimeInitializationStage.pluginInstalling,
      'ready' => RuntimeInitializationStage.ready,
      _ => null,
    };
    if (resolvedStage == null) return null;
    final normalizedDetail = detail?.trim();
    if (normalizedDetail != null &&
        (normalizedDetail.isEmpty ||
            normalizedDetail.length > 256 ||
            normalizedDetail.contains('\n') ||
            normalizedDetail.contains('\r'))) {
      return null;
    }
    return RuntimeInitializationProgress._(
      completedBytes: completedBytes,
      detail: normalizedDetail,
      stage: resolvedStage,
      totalBytes: totalBytes,
    );
  }
}
