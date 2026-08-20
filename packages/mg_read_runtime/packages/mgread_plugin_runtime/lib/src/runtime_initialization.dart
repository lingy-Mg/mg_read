part of mgread_plugin_runtime;

/// Bounded Runtime-owned initialization phase safe for Flutter presentation.
enum RuntimeInitializationStage {
  assetsCopying,
  assetsCopied,
  assetsReused,
  nodeStarting,
  ready,
}

/// Actual native initialization progress without paths, archive names or data.
@immutable
final class RuntimeInitializationProgress {
  const RuntimeInitializationProgress._({
    required this.completedBytes,
    required this.stage,
    required this.totalBytes,
  });

  final int completedBytes;
  final RuntimeInitializationStage stage;
  final int totalBytes;

  double? get fraction => totalBytes == 0 ? null : completedBytes / totalBytes;

  static RuntimeInitializationProgress? fromPlatform({
    required int completedBytes,
    required String stage,
    required int totalBytes,
  }) {
    final resolvedStage = switch (stage) {
      'assets_copying' => RuntimeInitializationStage.assetsCopying,
      'assets_copied' => RuntimeInitializationStage.assetsCopied,
      'assets_reused' => RuntimeInitializationStage.assetsReused,
      'node_starting' => RuntimeInitializationStage.nodeStarting,
      'ready' => RuntimeInitializationStage.ready,
      _ => null,
    };
    if (resolvedStage == null) return null;
    return RuntimeInitializationProgress._(
      completedBytes: completedBytes,
      stage: resolvedStage,
      totalBytes: totalBytes,
    );
  }
}
