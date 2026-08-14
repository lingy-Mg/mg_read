import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/app/app_theme_mode_scope.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/library/application/library_page_controller.dart';
import 'package:mg_read/features/library/application/library_page_state.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_home_shell.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';

/// The library landing page driven by immutable lifecycle and display state.
class LibraryPage extends ConsumerWidget {
  /// Creates the library landing page.
  ///
  /// [previewData] is used only while the current M2 loader deliberately
  /// returns an empty local projection. The default fixture is visibly
  /// disclosed and is never passed to a repository or reader route.
  const LibraryPage({
    this.previewData,
    this.callbacks = const LibraryHomeCallbacks(),
    this.onDestinationRequested,
    super.key,
  });

  final LibraryHomeViewData? previewData;
  final LibraryHomeCallbacks callbacks;

  /// Lets the app layer own switching among top-level destinations.
  final ValueChanged<AppNavigationDestination>? onDestinationRequested;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppThemeModeScope themeModeScope = AppThemeModeScope.of(context);
    final LibraryPageState state = ref.watch(libraryPageControllerProvider);
    final LibraryPageController controller = ref.read(
      libraryPageControllerProvider.notifier,
    );

    if (state.status == LibraryPageStatus.initialLoading) {
      return const _LibraryLoadingState();
    }
    if (state.overview == null) {
      return _LibraryFailureState(
        error: state.error!,
        onRetry: controller.refresh,
      );
    }

    final LibraryHomeViewData data = state.overview!.isEmpty
        ? previewData ?? LibraryHomeFixtures.preview
        : LibraryHomeViewData.fromLocalOverview(state.overview!);
    final ValueChanged<AppNavigationDestination>? destinationRequested =
        onDestinationRequested;
    final LibraryHomeCallbacks resolvedCallbacks = destinationRequested == null
        ? callbacks
        : callbacks.copyWith(
            onNavigationSelected: (AppNavigationDestination destination) {
              callbacks.onNavigationSelected?.call(destination);
              destinationRequested(destination);
            },
          );
    return LibraryHomeShell(
      data: data,
      callbacks: resolvedCallbacks,
      isRefreshing: state.status == LibraryPageStatus.refreshing,
      onRefresh: controller.refresh,
      onToggleTheme: () {
        themeModeScope.onToggleTheme(Theme.of(context).brightness);
      },
      errorNotice: state.hasFailure
          ? _LibraryErrorCard(
              error: state.error!,
              onRetry: controller.refresh,
              hasRetainedData: true,
            )
          : null,
    );
  }
}

class _LibraryLoadingState extends StatelessWidget {
  const _LibraryLoadingState();

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Semantics(
            label: '正在加载书架',
            child: ExcludeSemantics(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  CircularProgressIndicator(color: tokens.accent),
                  const SizedBox(height: AppSpacing.regular),
                  Text(
                    '正在加载书架',
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LibraryFailureState extends StatelessWidget {
  const _LibraryFailureState({required this.error, required this.onRetry});

  final AppError error;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.section),
              child: _LibraryErrorCard(error: error, onRetry: onRetry),
            ),
          ),
        ),
      ),
    );
  }
}

class _LibraryErrorCard extends StatelessWidget {
  const _LibraryErrorCard({
    required this.error,
    required this.onRetry,
    this.hasRetainedData = false,
  });

  final AppError error;
  final Future<void> Function() onRetry;
  final bool hasRetainedData;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer,
          borderRadius: AppRadii.surface,
          border: Border.all(color: theme.colorScheme.error),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.comfortable),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                _errorTitle(error),
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
              const SizedBox(height: AppSpacing.compact),
              Text(
                _errorDescription(error),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
              if (hasRetainedData) ...<Widget>[
                const SizedBox(height: AppSpacing.compact),
                Text(
                  '已保留上次成功加载的数据。',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ],
              if (error.retryable) ...<Widget>[
                const SizedBox(height: AppSpacing.comfortable),
                FilledButton(
                  onPressed: () {
                    unawaited(onRetry());
                  },
                  child: const Text('重试'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

String _errorTitle(AppError error) {
  return switch (error.category) {
    AppErrorCategory.retryableTemporary => '暂时无法完成请求',
    AppErrorCategory.runtimeUnavailable => '运行环境不可用',
    AppErrorCategory.pluginUnavailable => '插件不可用',
    AppErrorCategory.interactionRequired => '需要用户交互',
    AppErrorCategory.contentUnavailable => '内容不可用',
    AppErrorCategory.storagePressure => '存储空间不足',
    AppErrorCategory.incompatible => '版本不兼容',
    AppErrorCategory.cancelled => '操作已取消',
    AppErrorCategory.unknownSafe => '无法安全完成请求',
  };
}

String _errorDescription(AppError error) {
  return switch (error.category) {
    AppErrorCategory.retryableTemporary => '请稍后重试。',
    AppErrorCategory.runtimeUnavailable => '请重启应用后重试；诊断入口将在后续交付包提供。',
    AppErrorCategory.pluginUnavailable => '请在后续插件管理功能中检查插件状态。',
    AppErrorCategory.interactionRequired => '当前版本尚未提供所需的交互能力。',
    AppErrorCategory.contentUnavailable => '请返回上一层并选择其他可用内容。',
    AppErrorCategory.storagePressure => '请释放可再生缓存或存储空间后重试。',
    AppErrorCategory.incompatible => '请更新应用或恢复兼容的插件版本。',
    AppErrorCategory.cancelled => '当前页面保持最近的稳定状态。',
    AppErrorCategory.unknownSafe => '请稍后重试；如问题持续出现，请在诊断页面查看稳定错误码。',
  };
}
