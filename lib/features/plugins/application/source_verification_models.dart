/// 正式 App 内置数据源自检的稳定结果模型。
///
/// 职责：保存阶段状态、计数型摘要和可导出的紧凑报告。
/// 注意：不得保存 URL、搜索词、内容标题、正文、Cookie、凭据或原始异常。
library;

import 'package:flutter/foundation.dart';

enum SourceVerificationResultStatus {
  passed('passed'),
  failed('failed'),
  interactionRequired('interactionRequired'),
  cancelled('cancelled');

  const SourceVerificationResultStatus(this.code);
  final String code;
}

enum SourceVerificationStageStatus {
  passed('passed'),
  failed('failed'),
  skipped('skipped'),
  cancelled('cancelled');

  const SourceVerificationStageStatus(this.code);
  final String code;
}

@immutable
final class SourceVerificationStageResult {
  SourceVerificationStageResult({
    required this.stage,
    required this.status,
    required this.duration,
    this.code,
    Map<String, Object?> summary = const <String, Object?>{},
  }) : summary = Map<String, Object?>.unmodifiable(summary);

  final String stage;
  final SourceVerificationStageStatus status;
  final Duration duration;
  final String? code;
  final Map<String, Object?> summary;

  Map<String, Object?> toJson() => <String, Object?>{
    'stage': stage,
    'status': status.code,
    'durationMs': duration.inMilliseconds,
    if (code != null) 'code': code,
    if (summary.isNotEmpty) 'summary': summary,
  };
}

@immutable
final class SourceVerificationSourceResult {
  SourceVerificationSourceResult({
    required this.pluginId,
    required this.displayName,
    required this.version,
    required this.status,
    required this.duration,
    required List<SourceVerificationStageResult> stages,
  }) : stages = List<SourceVerificationStageResult>.unmodifiable(stages);

  final String pluginId;
  final String displayName;
  final String version;
  final SourceVerificationResultStatus status;
  final Duration duration;
  final List<SourceVerificationStageResult> stages;

  SourceVerificationStageResult? get failure => stages.where((stage) => stage.status == SourceVerificationStageStatus.failed).firstOrNull;

  Map<String, Object?> toJson() => <String, Object?>{
    'pluginId': pluginId,
    'version': version,
    'status': status.code,
    'durationMs': duration.inMilliseconds,
    'stages': stages.map((stage) => stage.toJson()).toList(growable: false),
  };
}

@immutable
final class SourceVerificationReport {
  SourceVerificationReport({
    required this.startedAt,
    required this.duration,
    required this.mode,
    required List<SourceVerificationSourceResult> sources,
    this.failureCode,
  }) : sources = List<SourceVerificationSourceResult>.unmodifiable(sources);

  final DateTime startedAt;
  final Duration duration;
  final String mode;
  final List<SourceVerificationSourceResult> sources;
  final String? failureCode;

  int get passedCount => sources.where((source) => source.status == SourceVerificationResultStatus.passed).length;
  int get failedCount => sources.where((source) => source.status == SourceVerificationResultStatus.failed).length;
  int get interactionRequiredCount => sources.where((source) => source.status == SourceVerificationResultStatus.interactionRequired).length;
  int get cancelledCount => sources.where((source) => source.status == SourceVerificationResultStatus.cancelled).length;
  bool get isSuccessful => failureCode == null && sources.isNotEmpty && passedCount == sources.length;

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': 1,
    'platform': 'windows',
    'mode': mode,
    'status': isSuccessful ? 'passed' : 'failed',
    'startedAt': startedAt.toUtc().toIso8601String(),
    'durationMs': duration.inMilliseconds,
    if (failureCode != null) 'failure': <String, Object?>{'code': failureCode},
    'totals': <String, Object?>{
      'sources': sources.length,
      'passed': passedCount,
      'failed': failedCount,
      'interactionRequired': interactionRequiredCount,
      'cancelled': cancelledCount,
    },
    'sources': sources.map((source) => source.toJson()).toList(growable: false),
  };
}

@immutable
final class SourceVerificationProgress {
  const SourceVerificationProgress({required this.pluginId, required this.displayName, required this.stage, required this.running});

  final String pluginId;
  final String displayName;
  final String stage;
  final bool running;
}

final class SourceVerificationCancellationToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

final class SourceVerificationRunException implements Exception {
  const SourceVerificationRunException(this.code);

  final String code;

  @override
  String toString() => 'SourceVerificationRunException($code)';
}
