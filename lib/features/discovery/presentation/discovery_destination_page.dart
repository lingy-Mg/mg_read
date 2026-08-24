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
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/presentation/runtime_discovery_page.dart';
import 'package:mg_read/features/discovery/presentation/source_content_detail_sheet.dart';
import 'package:mg_read/features/discovery/presentation/source_picker_sheet.dart';
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
    super.key,
  });

  final ValueChanged<AppNavigationDestination> onDestinationRequested;
  final ValueChanged<String?>? onSearchRequested;
  final VoidCallback? onSourceManagementRequested;
  final SourceTextChapterRequested? onTextChapterRequested;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(discoveryPageControllerProvider);
    final controller = ref.read(discoveryPageControllerProvider.notifier);
    final bookshelfMembership = ref.watch(bookshelfMembershipProvider);

    final selectedSource = _selectedSource(state);
    if (selectedSource != null &&
        (state.result != null ||
            state.status == DiscoveryPageStatus.loadingContent ||
            state.status == DiscoveryPageStatus.failure ||
            state.status == DiscoveryPageStatus.empty)) {
      return RuntimeDiscoveryPage(
        result: state.result,
        sourceName: selectedSource.displayName,
        onDestinationRequested: onDestinationRequested,
        onSearchRequested: onSearchRequested == null
            ? null
            : () => onSearchRequested!(state.selectedSourceId),
        onSourcePressed: () => _selectSource(context, state, controller),
        onTabSelected: (target) => unawaited(controller.selectTab(target)),
        onCategorySelected: (target) =>
            unawaited(controller.openCategory(target)),
        isInBookshelf: (content) => bookshelfMembership.contains(
          pluginId: state.selectedSourceId!,
          title: content.title,
        ),
        onContentPressed: (content) {
          final result = state.result;
          if (result == null) return;
          final saver = ref.read(discoveryBookshelfSaverProvider);
          unawaited(
            showSourceContentDetailSheet(
              context,
              gateway: ref.read(sourceContentGatewayProvider),
              pluginId: state.selectedSourceId!,
              id: content.id,
              initialContent: content,
              initialSourceName: selectedSource.displayName,
              relatedContents: _discoveryContentSummaries(result),
              onTextChapterRequested: onTextChapterRequested,
              shelfState:
                  bookshelfMembership.contains(
                    pluginId: state.selectedSourceId!,
                    title: content.title,
                  )
                  ? SourceDetailShelfState.alreadyAdded
                  : SourceDetailShelfState.canAdd,
              onAddToShelf: (content) =>
                  saver.save(source: selectedSource, content: content),
            ),
          );
        },
        onRefreshRequested: () => unawaited(controller.refresh()),
        onLoadMore: (collection) => unawaited(controller.loadMore(collection)),
        canNavigateBack: state.canNavigateBack,
        onBackRequested: controller.goBack,
        loadingCollectionId: state.loadingCollectionId,
        isContentLoading: state.status == DiscoveryPageStatus.loadingContent,
        contentIsEmpty: state.status == DiscoveryPageStatus.empty,
        contentFailureMessage: state.status == DiscoveryPageStatus.failure
            ? _sourceErrorTitle(state.error!)
            : null,
        contentFailureCode: state.status == DiscoveryPageStatus.failure
            ? state.error!.code.wireValue
            : null,
      );
    }

    final content = switch (state.status) {
      DiscoveryPageStatus.loadingSources => const _DiscoveryStateContent(
        key: Key('discovery-loading-sources'),
        icon: Icons.extension_rounded,
        title: '正在读取可用书源',
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
        title: '没有可用书源',
        message: '请先安装并启用支持小说或漫画内容的插件。',
      ),
      DiscoveryPageStatus.empty => _DiscoveryStateContent(
        key: const Key('discovery-empty'),
        icon: Icons.inbox_outlined,
        title: '当前书源没有发现内容',
        message: '插件返回了空分区；这不是缺失字段，也不会用演示数据替代。',
        actionLabel: '刷新',
        onAction: () => unawaited(controller.refresh()),
      ),
      DiscoveryPageStatus.failure => _DiscoveryStateContent(
        key: const Key('discovery-failure'),
        icon: Icons.error_outline_rounded,
        title: _sourceErrorTitle(state.error!),
        message: '稳定错误码：${state.error!.code.wireValue}',
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
              tooltip: Theme.of(context).brightness == Brightness.dark
                  ? '切换至浅色模式'
                  : '切换至深色模式',
              onPressed: () {
                AppThemeModeScope.of(
                  context,
                ).onToggleTheme(Theme.of(context).brightness);
              },
              icon: Icon(
                Theme.of(context).brightness == Brightness.dark
                    ? Icons.light_mode_outlined
                    : Icons.dark_mode_outlined,
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.section),
              child: content,
            ),
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

  Future<void> _selectSource(
    BuildContext context,
    DiscoveryPageState state,
    DiscoveryPageController controller,
  ) async {
    final selected = await showDiscoverySourcePicker(
      context,
      sources: state.sources,
      selectedSourceId: state.selectedSourceId!,
    );
    switch (selected) {
      case DiscoverySourceSelected(:final sourceId):
        await controller.selectSource(sourceId);
      case DiscoverySourceManagementRequested():
        onSourceManagementRequested?.call();
      case null:
        return;
    }
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

Iterable<PluginContentSummary> _discoveryContentSummaries(
  PluginDiscoverResult result,
) sync* {
  switch (result) {
    case PluginDiscoveryAppendResult(:final items):
      yield* items.map((item) => item.content);
    case PluginDiscoveryDocumentResult(:final document):
      yield* _documentContentSummaries(document.components);
  }
}

Iterable<PluginContentSummary> _documentContentSummaries(
  Iterable<PluginDiscoveryComponent> components,
) sync* {
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
          if (loading)
            CircularProgressIndicator(color: tokens.accent)
          else
            Icon(icon, size: 48, color: tokens.mutedText),
          const SizedBox(height: AppSpacing.comfortable),
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpacing.compact),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: tokens.mutedText,
            ),
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
