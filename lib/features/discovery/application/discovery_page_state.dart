/// 发现页不可变状态快照。
///
/// 职责：
/// - 表示数据源、当前文档和内部层级导航状态。
/// - 在子页加载期间保留父页快照，供展示层完成入场与立即返回。
/// - 投影只读父级快照链，供系统返回手势预览正确的直接父页。
///
/// 注意：
/// - 不保存可变控制器或 Runtime 句柄。
/// - target 仅作不透明请求标识，不能用于展示或诊断内容。
///
library;

import 'package:flutter/foundation.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';

enum DiscoveryPageStatus { loadingSources, loadingContent, loaded, empty, noSources, failure }

@immutable
final class DiscoveryPageState {
  DiscoveryPageState._({
    required this.status,
    required Iterable<PluginSourceDescriptor> sources,
    required this.selectedSourceId,
    required this.result,
    required this.error,
    required this.canNavigateBack,
    required this.loadingCollectionId,
    required this.navigationDepth,
    required this.target,
    required this.previousResult,
    required Iterable<PluginDiscoveryDocumentResult> retainedParents,
  }) : sources = List<PluginSourceDescriptor>.unmodifiable(sources),
       retainedParents = List<PluginDiscoveryDocumentResult>.unmodifiable(retainedParents);

  factory DiscoveryPageState.loadingSources() => DiscoveryPageState._(
    status: DiscoveryPageStatus.loadingSources,
    sources: const <PluginSourceDescriptor>[],
    selectedSourceId: null,
    result: null,
    error: null,
    canNavigateBack: false,
    loadingCollectionId: null,
    navigationDepth: 0,
    target: null,
    previousResult: null,
    retainedParents: const <PluginDiscoveryDocumentResult>[],
  );

  factory DiscoveryPageState.loadingContent({
    required Iterable<PluginSourceDescriptor> sources,
    required String selectedSourceId,
    required bool canNavigateBack,
    required int navigationDepth,
    required String? target,
    PluginDiscoveryDocumentResult? previousResult,
    Iterable<PluginDiscoveryDocumentResult> retainedParents = const <PluginDiscoveryDocumentResult>[],
  }) => DiscoveryPageState._(
    status: DiscoveryPageStatus.loadingContent,
    sources: sources,
    selectedSourceId: selectedSourceId,
    result: null,
    error: null,
    canNavigateBack: canNavigateBack,
    loadingCollectionId: null,
    navigationDepth: navigationDepth,
    target: target,
    previousResult: previousResult,
    retainedParents: retainedParents,
  );

  factory DiscoveryPageState.resolved({
    required Iterable<PluginSourceDescriptor> sources,
    required String selectedSourceId,
    required PluginDiscoveryDocumentResult result,
    required bool isEmpty,
    required bool canNavigateBack,
    required int navigationDepth,
    required String? target,
    String? loadingCollectionId,
    Iterable<PluginDiscoveryDocumentResult> retainedParents = const <PluginDiscoveryDocumentResult>[],
  }) => DiscoveryPageState._(
    status: isEmpty ? DiscoveryPageStatus.empty : DiscoveryPageStatus.loaded,
    sources: sources,
    selectedSourceId: selectedSourceId,
    result: result,
    error: null,
    canNavigateBack: canNavigateBack,
    loadingCollectionId: loadingCollectionId,
    navigationDepth: navigationDepth,
    target: target,
    previousResult: null,
    retainedParents: retainedParents,
  );

  factory DiscoveryPageState.noSources() => DiscoveryPageState._(
    status: DiscoveryPageStatus.noSources,
    sources: const <PluginSourceDescriptor>[],
    selectedSourceId: null,
    result: null,
    error: null,
    canNavigateBack: false,
    loadingCollectionId: null,
    navigationDepth: 0,
    target: null,
    previousResult: null,
    retainedParents: const <PluginDiscoveryDocumentResult>[],
  );

  factory DiscoveryPageState.failure({
    required Iterable<PluginSourceDescriptor> sources,
    required String? selectedSourceId,
    required AppError error,
    required bool canNavigateBack,
    required int navigationDepth,
    required String? target,
    PluginDiscoveryDocumentResult? previousResult,
    Iterable<PluginDiscoveryDocumentResult> retainedParents = const <PluginDiscoveryDocumentResult>[],
  }) => DiscoveryPageState._(
    status: DiscoveryPageStatus.failure,
    sources: sources,
    selectedSourceId: selectedSourceId,
    result: null,
    error: error,
    canNavigateBack: canNavigateBack,
    loadingCollectionId: null,
    navigationDepth: navigationDepth,
    target: target,
    previousResult: previousResult,
    retainedParents: retainedParents,
  );

  final DiscoveryPageStatus status;
  final List<PluginSourceDescriptor> sources;
  final String? selectedSourceId;
  final PluginDiscoveryDocumentResult? result;
  final AppError? error;
  final bool canNavigateBack;
  final String? loadingCollectionId;
  final int navigationDepth;
  final String? target;
  final PluginDiscoveryDocumentResult? previousResult;
  final List<PluginDiscoveryDocumentResult> retainedParents;

  DiscoveryPageState withSources(Iterable<PluginSourceDescriptor> value) => DiscoveryPageState._(
    status: status,
    sources: value,
    selectedSourceId: selectedSourceId,
    result: result,
    error: error,
    canNavigateBack: canNavigateBack,
    loadingCollectionId: loadingCollectionId,
    navigationDepth: navigationDepth,
    target: target,
    previousResult: previousResult,
    retainedParents: retainedParents,
  );
}
