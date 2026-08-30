/// 数据源 Runtime 应用层模型。
///
/// 职责：
/// - 定义主应用消费的脱敏 Runtime 状态与数据源投影。
/// - 保持 presentation 与 Runtime Facade 的稳定类型边界。
///
/// 注意：
/// - 不包含 Runtime wire DTO、路径、端口或资源 token。
/// - 模型不可变，异步更新由 application controller 负责。
///
library;

import 'package:flutter/foundation.dart';

@immutable
final class PluginRuntimeConnection {
  const PluginRuntimeConnection({
    required this.isHealthy,
    required this.nodeVersion,
    required this.runtimeVersion,
    required this.plugins,
    this.startupRecovery = const PluginRuntimeStartupRecovery(quarantinedCount: 0),
  });

  final bool isHealthy;
  final String nodeVersion;
  final String runtimeVersion;
  final List<PluginRuntimePlugin> plugins;
  final PluginRuntimeStartupRecovery startupRecovery;
}

@immutable
final class PluginRuntimeStartupRecovery {
  const PluginRuntimeStartupRecovery({required this.quarantinedCount});

  final int quarantinedCount;
}

@immutable
final class PluginRuntimeStatus {
  const PluginRuntimeStatus({
    required this.arch,
    required this.isHealthy,
    required this.memory,
    required this.nodeVersion,
    required this.platform,
    required this.plugins,
    required this.runtimeVersion,
    required this.runtimeKind,
    required this.uptime,
  });

  final String arch;
  final bool isHealthy;
  final PluginRuntimeMemory memory;
  final String nodeVersion;
  final String platform;
  final List<PluginRuntimePlugin> plugins;
  final String runtimeVersion;
  final String runtimeKind;
  final Duration uptime;
}

@immutable
final class PluginRuntimeMemory {
  const PluginRuntimeMemory({
    required this.arrayBuffers,
    required this.external,
    required this.heapTotal,
    required this.heapUsed,
    required this.rss,
  });

  final int arrayBuffers;
  final int external;
  final int heapTotal;
  final int heapUsed;
  final int rss;
}

@immutable
final class PluginRuntimePlugin {
  const PluginRuntimePlugin({
    required this.activeVersion,
    required this.contentKinds,
    required this.displayName,
    required this.enabled,
    required this.id,
    required this.name,
    required this.pendingVersion,
    required this.status,
    this.description,
    this.iconUrl,
  });

  final String? activeVersion;
  final List<String> contentKinds;
  final String? description;
  final String displayName;
  final bool enabled;
  final String? iconUrl;
  final String id;
  final String name;
  final String? pendingVersion;
  final String status;
}
