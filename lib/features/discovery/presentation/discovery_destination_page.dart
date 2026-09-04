/// Runtime 驱动的发现页入口。
///
/// 职责：
/// - 将发现页不可变状态接线到 Runtime 内容渲染器。
/// - 将详情、书架和数据源选择委派给各自应用服务。
///
/// 注意：
/// - 页面不在 build 中进行 IO；内部层级由 controller 栈而非 GoRouter 管理。
/// - 子页面只接收其层级状态，数据源选择仅显示在顶级发现页。
///
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/app/app_theme_mode_scope.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/discovery/application/discovery_page_controller.dart';
import 'package:mg_read/features/discovery/application/discovery_page_state.dart';
import 'package:mg_read/features/discovery/application/bookshelf_membership.dart';
import 'package:mg_read/features/discovery/application/discovery_bookshelf_saver.dart';
import 'package:mg_read/features/discovery/application/discovery_bookshelf_remover.dart';
import 'package:mg_read/features/discovery/application/discovery_source_selection_store.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/presentation/runtime_discovery_page.dart';
import 'package:mg_read/features/discovery/presentation/source_content_detail_sheet.dart';
import 'package:mg_read/features/discovery/presentation/source_picker_sheet.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_bottom_navigation.dart';
import 'package:mg_read/shared/presentation/widgets/app_page_title.dart';

/// Runtime-backed discovery destination that keeps transport out of widgets.
class DiscoveryDestinationPage extends ConsumerWidget {
  const DiscoveryDestinationPage({
    required this.onDestinationRequested,
    this.onSearchRequested,
    this.onSourceManagementRequested,
    this.onTextChapterRequested,
    this.onComicChapterRequested,
    this.onAudioChapterRequested,
    this.onVideoEpisodeRequested,
    super.key,
  });

  final ValueChanged<AppNavigationDestination> onDestinationRequested;
  final ValueChanged<String?>? onSearchRequested;
  final VoidCallback? onSourceManagementRequested;
  final SourceTextChapterRequested? onTextChapterRequested;
  final SourceComicChapterRequested? onComicChapterRequested;
  final SourceAudioChapterRequested? onAudioChapterRequested;
  final SourceVideoEpisodeRequested? onVideoEpisodeRequested;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(discoveryPageControllerProvider);
    final controller = ref.read(discoveryPageControllerProvider.notifier);

    final selectedSource = _selectedSource(state);
    if (selectedSource != null &&
        (state.result != null ||
            state.status == DiscoveryPageStatus.loadingContent ||
            state.status == DiscoveryPageStatus.failure ||
            state.status == DiscoveryPageStatus.empty)) {
      return _DiscoveryRuntimeLayer(
        visualDepth: 0,
        onDestinationRequested: onDestinationRequested,
        onSearchRequested: onSearchRequested,
        onSourceManagementRequested: onSourceManagementRequested,
        onTextChapterRequested: onTextChapterRequested,
        onComicChapterRequested: onComicChapterRequested,
        onAudioChapterRequested: onAudioChapterRequested,
        onVideoEpisodeRequested: onVideoEpisodeRequested,
      );
    }

    final content = switch (state.status) {
      DiscoveryPageStatus.loadingSources => const _DiscoveryStateContent(
        key: Key('discovery-loading-sources'),
        icon: Icons.extension_rounded,
        title: '正在读取可用数据源',
        message: 'Runtime 正在返回已启用的插件列表。',
        loading: true,
      ),
      DiscoveryPageStatus.loadingContent => const _DiscoveryStateContent(
        key: Key('discovery-loading-content'),
        icon: Icons.explore_rounded,
        title: '正在加载发现内容',
        message: '插件正在生成分区、榜单和分类。',
        loading: true,
      ),
      DiscoveryPageStatus.noSources => const _DiscoveryStateContent(
        key: Key('discovery-no-sources'),
        icon: Icons.extension_off_rounded,
        title: '没有可用数据源',
        message: '请先安装并启用支持小说或漫画内容的插件。',
      ),
      DiscoveryPageStatus.empty => _DiscoveryStateContent(
        key: const Key('discovery-empty'),
        icon: Icons.inbox_outlined,
        title: '当前数据源没有发现内容',
        message: '插件返回了空分区；这不是缺失字段，也不会用演示数据替代。',
        actionLabel: '刷新',
        onAction: () => unawaited(controller.refresh()),
      ),
      DiscoveryPageStatus.failure => _DiscoveryStateContent(
        key: const Key('discovery-failure'),
        icon: Icons.error_outline_rounded,
        title: _sourceErrorTitle(state.error!),
        message: '${_sourceErrorDetail(state.error!)}\n稳定错误码：${state.error!.code.wireValue}',
        actionLabel: '重试',
        onAction: () => unawaited(controller.retry()),
      ),
      DiscoveryPageStatus.loaded => throw StateError('Handled above.'),
    };

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: AppSpacing.pageHeaderHeight,
        title: const AppPageTitle(title: '发现'),
        actions: <Widget>[
          if (AppTheme.darkModeEnabled)
            IconButton(
              key: const Key('theme-mode-toggle'),
              tooltip: Theme.of(context).brightness == Brightness.dark ? '切换至浅色模式' : '切换至深色模式',
              onPressed: () {
                AppThemeModeScope.of(context).onToggleTheme(Theme.of(context).brightness);
              },
              icon: Icon(Theme.of(context).brightness == Brightness.dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
            ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(padding: const EdgeInsets.all(AppSpacing.section), child: content),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: AppBottomNavigation(
          selected: AppNavigationDestination.discover,
          onSelected: (destination) {
            if (destination != AppNavigationDestination.discover) {
              onDestinationRequested(destination);
            }
          },
        ),
      ),
    );
  }
}

/// Keeps one visual discovery layer bound to one controller snapshot depth.
///
/// A child layer is placed on the root Navigator only for Android's predictive
/// back preview. The controller remains the authority for document snapshots,
/// generations and final back commits.
class _DiscoveryRuntimeLayer extends ConsumerWidget {
  const _DiscoveryRuntimeLayer({
    required this.visualDepth,
    required this.onDestinationRequested,
    required this.onSearchRequested,
    required this.onSourceManagementRequested,
    required this.onTextChapterRequested,
    required this.onComicChapterRequested,
    required this.onAudioChapterRequested,
    required this.onVideoEpisodeRequested,
    this.isPredictiveBackRoute = false,
  });

  final int visualDepth;
  final ValueChanged<AppNavigationDestination> onDestinationRequested;
  final ValueChanged<String?>? onSearchRequested;
  final VoidCallback? onSourceManagementRequested;
  final SourceTextChapterRequested? onTextChapterRequested;
  final SourceComicChapterRequested? onComicChapterRequested;
  final SourceAudioChapterRequested? onAudioChapterRequested;
  final SourceVideoEpisodeRequested? onVideoEpisodeRequested;
  final bool isPredictiveBackRoute;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(discoveryPageControllerProvider);
    final controller = ref.read(discoveryPageControllerProvider.notifier);
    final bookshelfMembership = ref.watch(bookshelfMembershipProvider);
    final selectedSource = _selectedSource(state);
    if (selectedSource == null) return const SizedBox.shrink();

    final bool isCoveredByChild = visualDepth < state.navigationDepth;
    final PluginDiscoveryDocumentResult? displayedResult = isCoveredByChild
        ? visualDepth < state.retainedParents.length
              ? state.retainedParents[visualDepth]
              : state.previousResult
        : state.result;
    final bool isActiveLayer = !isCoveredByChild;
    final bool canNavigateBack = visualDepth > 0;

    Future<void> openContent(PluginContentSummary content) {
      final result = displayedResult;
      if (result == null) return Future<void>.value();
      final pluginId = state.selectedSourceId!;
      final saver = ref.read(discoveryBookshelfSaverProvider);
      final remover = ref.read(discoveryBookshelfRemoverProvider);
      final currentMembership = ref.read(bookshelfMembershipProvider);
      return showSourceContentDetailSheet(
        context,
        gateway: ref.read(sourceContentGatewayProvider),
        pluginId: pluginId,
        pluginVersion: selectedSource.pluginVersion,
        id: content.id,
        initialContent: content,
        initialSourceName: selectedSource.displayName,
        relatedContents: _discoveryContentSummaries(result),
        onTextChapterRequested: onTextChapterRequested,
        onComicChapterRequested: onComicChapterRequested,
        onAudioChapterRequested: onAudioChapterRequested,
        onVideoEpisodeRequested: onVideoEpisodeRequested,
        shelfState: currentMembership.contains(pluginId: pluginId, title: content.title)
            ? SourceDetailShelfState.alreadyAdded
            : SourceDetailShelfState.canAdd,
        onAddToShelf: (detail) => saver.save(source: selectedSource, detail: detail),
        onRemoveFromShelf: remover == null ? null : () => remover.remove(pluginId: pluginId, title: content.title),
        onRecommendationRequested: openContent,
      );
    }

    return RuntimeDiscoveryPage(
      result: displayedResult,
      sourceName: selectedSource.displayName,
      onDestinationRequested: onDestinationRequested,
      onSearchRequested: onSearchRequested == null ? null : () => onSearchRequested!(state.selectedSourceId),
      onSourcePressed: () => unawaited(_selectDiscoverySource(context, ref, state, controller, onSourceManagementRequested)),
      onTabSelected: (target) => unawaited(controller.selectTab(target)),
      onCategorySelected: (target) => _pushCategoryRoute(context, ref, controller, target),
      isInBookshelf: (content) => bookshelfMembership.contains(pluginId: state.selectedSourceId!, title: content.title),
      onContentPressed: (content) => unawaited(openContent(content)),
      onRefreshRequested: () => unawaited(controller.refresh()),
      onLoadMore: (collection) => unawaited(controller.loadMore(collection)),
      canNavigateBack: canNavigateBack,
      onBackRequested: isPredictiveBackRoute ? () => Navigator.of(context).pop() : controller.goBack,
      loadingCollectionId: isActiveLayer ? state.loadingCollectionId : null,
      navigationDepth: visualDepth,
      allowsRoutePop: isPredictiveBackRoute,
      isContentLoading: isActiveLayer && state.status == DiscoveryPageStatus.loadingContent,
      contentIsEmpty: isActiveLayer && state.status == DiscoveryPageStatus.empty,
      contentFailureMessage: isActiveLayer && state.status == DiscoveryPageStatus.failure ? _sourceErrorTitle(state.error!) : null,
      contentFailureDetail: isActiveLayer && state.status == DiscoveryPageStatus.failure ? _sourceErrorDetail(state.error!) : null,
      contentFailureCode: isActiveLayer && state.status == DiscoveryPageStatus.failure ? state.error!.code.wireValue : null,
    );
  }

  void _pushCategoryRoute(BuildContext context, WidgetRef ref, DiscoveryPageController controller, String target) {
    unawaited(controller.openCategory(target));
    final int childDepth = ref.read(discoveryPageControllerProvider).navigationDepth;
    if (childDepth <= visualDepth) return;
    Navigator.of(context, rootNavigator: true).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext routeContext) => _DiscoveryPredictiveBackChildPage(
          visualDepth: childDepth,
          onDestinationRequested: onDestinationRequested,
          onSearchRequested: onSearchRequested,
          onSourceManagementRequested: onSourceManagementRequested,
          onTextChapterRequested: onTextChapterRequested,
          onComicChapterRequested: onComicChapterRequested,
          onAudioChapterRequested: onAudioChapterRequested,
          onVideoEpisodeRequested: onVideoEpisodeRequested,
        ),
      ),
    );
  }
}

/// A locally routed child layer that lets Android preview the retained parent.
class _DiscoveryPredictiveBackChildPage extends ConsumerWidget {
  const _DiscoveryPredictiveBackChildPage({
    required this.visualDepth,
    required this.onDestinationRequested,
    required this.onSearchRequested,
    required this.onSourceManagementRequested,
    required this.onTextChapterRequested,
    required this.onComicChapterRequested,
    required this.onAudioChapterRequested,
    required this.onVideoEpisodeRequested,
  });

  final int visualDepth;
  final ValueChanged<AppNavigationDestination> onDestinationRequested;
  final ValueChanged<String?>? onSearchRequested;
  final VoidCallback? onSourceManagementRequested;
  final SourceTextChapterRequested? onTextChapterRequested;
  final SourceComicChapterRequested? onComicChapterRequested;
  final SourceAudioChapterRequested? onAudioChapterRequested;
  final SourceVideoEpisodeRequested? onVideoEpisodeRequested;

  @override
  Widget build(BuildContext context, WidgetRef ref) => PopScope<void>(
    canPop: true,
    onPopInvokedWithResult: (bool didPop, _) {
      if (didPop) ref.read(discoveryPageControllerProvider.notifier).goBack();
    },
    child: _DiscoveryRuntimeLayer(
      visualDepth: visualDepth,
      onDestinationRequested: onDestinationRequested,
      onSearchRequested: onSearchRequested,
      onSourceManagementRequested: onSourceManagementRequested,
      onTextChapterRequested: onTextChapterRequested,
      onComicChapterRequested: onComicChapterRequested,
      onAudioChapterRequested: onAudioChapterRequested,
      onVideoEpisodeRequested: onVideoEpisodeRequested,
      isPredictiveBackRoute: true,
    ),
  );
}

Future<void> _selectDiscoverySource(
  BuildContext context,
  WidgetRef ref,
  DiscoveryPageState state,
  DiscoveryPageController controller,
  VoidCallback? onSourceManagementRequested,
) async {
  final pinStore = ref.read(discoverySourceSelectionStoreProvider);
  final pinnedSourceIds = await pinStore.loadPinned();
  if (!context.mounted) return;
  final selected = await showDiscoverySourcePicker(
    context,
    sources: state.sources,
    selectedSourceId: state.selectedSourceId!,
    pinnedSourceIds: pinnedSourceIds,
    onPinChanged: (sourceId, pinned) => pinStore.setPinned(sourceId, pinned: pinned),
  );
  switch (selected) {
    case DiscoverySourceSelected(:final sourceId):
      await controller.selectSource(sourceId);
    case DiscoverySourceManagementRequested():
      onSourceManagementRequested?.call();
    case DiscoverySourceWebViewActionRequested(:final sourceId, :final action):
      final source = state.sources.where((candidate) => candidate.id == sourceId).firstOrNull;
      if (source == null) return;
      try {
        await ref
            .read(pluginRuntimeGatewayProvider)
            .controlSourceWebView(
              pluginId: source.id,
              pluginName: source.displayName,
              action: switch (action) {
                DiscoverySourceWebViewAction.enterDebug => PluginWebViewDebugAction.enter,
                DiscoverySourceWebViewAction.show => PluginWebViewDebugAction.show,
              },
            );
      } on AppError {
        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('WebView 调试窗口打开失败，请稍后重试。')));
      }
    case null:
      return;
  }
}

PluginSourceDescriptor? _selectedSource(DiscoveryPageState state) {
  final selectedSourceId = state.selectedSourceId;
  if (selectedSourceId == null) return null;
  for (final source in state.sources) {
    if (source.id == selectedSourceId) return source;
  }
  return null;
}

Iterable<PluginContentSummary> _discoveryContentSummaries(PluginDiscoverResult result) sync* {
  switch (result) {
    case PluginDiscoveryAppendResult(:final items):
      yield* items.map((item) => item.content);
    case PluginDiscoveryDocumentResult(:final document):
      yield* _documentContentSummaries(document.components);
  }
}

Iterable<PluginContentSummary> _documentContentSummaries(Iterable<PluginDiscoveryComponent> components) sync* {
  for (final component in components) {
    switch (component) {
      case PluginDiscoveryContentCollectionComponent(:final items):
        yield* items.map((item) => item.content);
      case PluginDiscoveryGroupComponent(:final children):
        yield* _documentContentSummaries(children);
      case PluginDiscoverySectionComponent(:final children):
        yield* _documentContentSummaries(children);
      default:
        break;
    }
  }
}

class _DiscoveryStateContent extends StatelessWidget {
  const _DiscoveryStateContent({
    required this.icon,
    required this.title,
    required this.message,
    this.loading = false,
    this.actionLabel,
    this.onAction,
    super.key,
  });

  final IconData icon;
  final String title;
  final String message;
  final bool loading;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    return Semantics(
      liveRegion: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (loading) CircularProgressIndicator(color: tokens.accent) else Icon(icon, size: 48, color: tokens.mutedText),
          const SizedBox(height: AppSpacing.comfortable),
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpacing.compact),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
          ),
          if (actionLabel != null && onAction != null) ...<Widget>[
            const SizedBox(height: AppSpacing.comfortable),
            FilledButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    );
  }
}

String _sourceErrorTitle(AppError error) => switch (error.category) {
  AppErrorCategory.runtimeUnavailable => '插件运行环境不可用',
  AppErrorCategory.pluginUnavailable => '当前插件不可用',
  AppErrorCategory.incompatible => '插件或 Runtime 版本不兼容',
  AppErrorCategory.retryableTemporary => '暂时无法加载发现内容',
  _ => '无法安全加载发现内容',
};

String _sourceErrorDetail(AppError error) => <String>[
  '原因：${_sourceErrorReason(error)}',
  if (error.detail case final detail?) '详细信息：$detail',
  if (error.location case final location?) '位置：$location',
].join('\n');

String _sourceErrorReason(AppError error) => switch (error.code) {
  AppErrorCode.invalidFormat => '数据源返回内容未通过 Runtime 格式或大小校验。',
  AppErrorCode.pluginExecutionFailed => '数据源执行发现请求时发生错误。',
  AppErrorCode.timeout => '数据源请求在限时内未完成。',
  AppErrorCode.runtimeUnavailable || AppErrorCode.runtimeStartFailed || AppErrorCode.runtimeNotReady => 'Runtime 尚未就绪或已中断。',
  AppErrorCode.pluginNotFound || AppErrorCode.pluginDisabled || AppErrorCode.pluginDamaged => '当前数据源不可用。',
  _ => '请求未能安全完成。',
};
