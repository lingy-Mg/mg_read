/// 首页书架页面。
///
/// 职责：
/// - 将书架生命周期状态映射为首页展示和显式用户回调。
/// - 编排阅读预热、书架删除与隐私可见性变更。
///
/// 注意：
/// - 书架持久化只通过 application 窄用例和 Content Library adapter 执行。
/// - 页面异步回调在路由离开后不得继续导航。
///
/// TODO:
/// - 无。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/app/app_theme_mode_scope.dart';
import 'package:mg_read/app/app_startup.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/library/application/library_book_remover.dart';
import 'package:mg_read/features/library/application/library_book_detail_launcher.dart';
import 'package:mg_read/features/library/application/library_book_refresher.dart';
import 'package:mg_read/features/library/application/library_book_removal_operation.dart';
import 'package:mg_read/features/library/application/library_book_visibility_changer.dart';
import 'package:mg_read/features/library/application/library_page_controller.dart';
import 'package:mg_read/features/library/application/library_page_state.dart';
import 'package:mg_read/features/library/domain/library_item_summary.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';
import 'package:mg_read/features/library/presentation/library_book_list_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_home_shell.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/presentation/source_content_detail_sheet.dart';
import 'package:mg_read/features/reader/application/shelf_reader_launch_coordinator.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_loading_state.dart';
import 'package:mg_read/shared/presentation/widgets/async_book_cover_loader.dart';

/// The library landing page driven by immutable lifecycle and display state.
class LibraryPage extends ConsumerWidget {
  /// Creates the library landing page.
  ///
  /// [previewData] is a test-only display override. Production empty states
  /// always render the first-run bookshelf experience.
  const LibraryPage({
    this.previewData,
    this.callbacks = const LibraryHomeCallbacks(),
    this.onDestinationRequested,
    this.onReaderRequested,
    this.onBookDetailRequested,
    this.onPrivacyLibraryRequested,
    this.onReadingHistoryRequested,
    this.onManageSourcesRequested,
    super.key,
  });

  final LibraryHomeViewData? previewData;
  final LibraryHomeCallbacks callbacks;

  /// Lets the app layer own switching among top-level destinations.
  final ValueChanged<AppNavigationDestination>? onDestinationRequested;

  /// Lets the app layer resolve a persisted shelf item for reading.
  final ValueChanged<String>? onReaderRequested;

  /// Lets the app layer open a persisted shelf item's detail surface.
  final ValueChanged<String>? onBookDetailRequested;

  /// Lets the app route own navigation to the private bookshelf.
  final VoidCallback? onPrivacyLibraryRequested;

  /// Lets the app route own navigation to the reading-history page.
  final VoidCallback? onReadingHistoryRequested;

  /// Lets the app route own navigation to data-source management.
  final VoidCallback? onManageSourcesRequested;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppThemeModeScope themeModeScope = AppThemeModeScope.of(context);
    final AppSettingsManager settings = ref.read(appSettingsProvider);
    final LibraryHomeLayoutMode initialLayoutMode = LibraryHomeLayoutMode.fromSetting(settings.snapshot.get(AppSettingKeys.homeLayoutMode));
    final LibraryPageState state = ref.watch(libraryPageControllerProvider);
    final LibraryPageController controller = ref.read(libraryPageControllerProvider.notifier);
    final LibraryBookRemover? bookRemover = ref.read(libraryBookRemoverProvider);
    final LibraryBookVisibilityChanger? visibilityChanger = ref.read(libraryBookVisibilityChangerProvider);
    final DiagnosticsManager diagnostics = ref.read(diagnosticsManagerProvider);
    final ShelfReaderLaunchState readerLaunch = ref.watch(shelfReaderLaunchCoordinatorProvider);
    final ShelfReaderLaunchCoordinator readerCoordinator = ref.read(shelfReaderLaunchCoordinatorProvider.notifier);
    final AppStartupController startup = ref.read(appStartupControllerProvider);

    if (state.status == LibraryPageStatus.initialLoading) {
      return _LibraryLoadingState(showAnimation: !startup.ownsLoadingAnimation);
    }
    if (state.overview == null) {
      return _LibraryTerminalFrameSignal(
        startup: startup,
        resultState: 'failure',
        child: _LibraryFailureState(error: state.error!, onRetry: controller.refresh),
      );
    }

    final LibraryHomeViewData data = state.overview!.isEmpty
        ? previewData ?? LibraryHomeViewData.empty()
        : LibraryHomeViewData.fromLocalOverview(state.overview!);
    final ValueChanged<AppNavigationDestination>? destinationRequested = onDestinationRequested;
    final ValueChanged<String>? readerRequested = onReaderRequested;
    final ValueChanged<String>? bookDetailRequested = onBookDetailRequested;
    final LibraryBookDetailLauncher? detailLauncher = ref.read(libraryBookDetailLauncherProvider);
    final LibraryBookRefresher? bookRefresher = ref.read(libraryBookRefresherProvider);
    final SourceContentGateway sourceGateway = ref.read(sourceContentGatewayProvider);
    void prepareAndOpen(String bookId) {
      final callback = readerRequested;
      if (callback == null) return;
      unawaited(() async {
        final prepared = await readerCoordinator.prepare(bookId);
        if (!context.mounted) {
          readerCoordinator.cancel(bookId, resultState: 'shelfDisposed');
          return;
        }
        if (!prepared) {
          if (context.mounted) {
            final failure = ref.read(shelfReaderLaunchCoordinatorProvider).failure;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(failure?.reason.userMessage ?? '阅读内容准备失败，请稍后重试。'),
                action: SnackBarAction(label: '重试', onPressed: () => prepareAndOpen(bookId)),
              ),
            );
          }
          return;
        }
        if (!readerCoordinator.claimNavigation(bookId)) return;
        callback(bookId);
      }());
    }

    final LibraryBookRemovalOperation? removalOperation = bookRemover == null
        ? null
        : LibraryBookRemovalOperation(remover: bookRemover, controller: controller, diagnostics: diagnostics);
    late LibraryHomeCallbacks resolvedCallbacks;
    Future<void> refreshBook(LibraryBookListItemViewData book) async {
      final refresher = bookRefresher;
      if (refresher == null) throw StateError('Book refresh is unavailable.');
      final request = book.coverRequest;
      await refresher.refresh(book.id);
      if (request != null) {
        BookCoverMemoryCache.remove(request);
        ref.invalidate(bookCoverBytesProvider(request));
      }
      await controller.refresh();
    }

    Future<void> openBookDetail(LibraryBookListItemViewData book) async {
      final externalCallback = bookDetailRequested;
      if (externalCallback != null) {
        externalCallback(book.id);
        return;
      }
      if (detailLauncher == null) {
        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('书籍详情暂不可用。')));
        return;
      }
      final LibraryItemSummary? summary = state.overview!.items.cast<LibraryItemSummary?>().firstWhere(
        (item) => item?.id == book.id,
        orElse: () => null,
      );
      final seed = detailLauncher
          .load(book.id)
          .then<SourceContentDetailSeed>(
            (detail) => SourceContentDetailSeed(
              pluginId: detail.pluginId,
              id: detail.remoteContentId,
              initialContent: detail.initialContent,
              initialCatalog: detail.initialCatalog,
              sourceName: detail.sourceName,
            ),
          );
      await showDeferredSourceContentDetailSheet(
        context,
        seed: seed,
        previewContent: _libraryDetailPreview(summary, book),
        gateway: sourceGateway,
        shelfState: SourceDetailShelfState.alreadyAdded,
        onTextChapterRequested: ({required detail, required firstCatalogPage, required chapter, required entryCoverBytes}) async {
          prepareAndOpen(book.id);
        },
        onStartReading: () async => prepareAndOpen(book.id),
        onShelfAction: (SourceShelfAction action) async {
          switch (action) {
            case SourceShelfAction.refresh:
              await refreshBook(book);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('《${book.title}》已刷新')));
              }
            case SourceShelfAction.setPrivate:
              await resolvedCallbacks.onSetBookPrivate?.call(book);
            case SourceShelfAction.cancelPrivate:
              break;
            case SourceShelfAction.delete:
              await resolvedCallbacks.onDeleteBook?.call(book);
          }
        },
      );
    }

    resolvedCallbacks = callbacks.copyWith(
      onNavigationSelected: destinationRequested == null
          ? callbacks.onNavigationSelected
          : (AppNavigationDestination destination) {
              callbacks.onNavigationSelected?.call(destination);
              destinationRequested(destination);
            },
      onDiscover: destinationRequested == null
          ? callbacks.onDiscover
          : () {
              callbacks.onDiscover?.call();
              destinationRequested(AppNavigationDestination.discover);
            },
      onOpenBook: bookDetailRequested == null
          ? readerRequested == null
                ? callbacks.onOpenBook
                : (book) {
                    callbacks.onOpenBook?.call(book);
                    prepareAndOpen(book.id);
                  }
          : (book) {
              callbacks.onOpenBook?.call(book);
              bookDetailRequested(book.id);
            },
      onBookLongPress: callbacks.onBookLongPress ?? openBookDetail,
      onRefreshBook: bookRefresher == null
          ? callbacks.onRefreshBook
          : (book) async {
              await callbacks.onRefreshBook?.call(book);
              await refreshBook(book);
            },
      onContinueReading: readerRequested == null || data.continueReading == null
          ? callbacks.onContinueReading
          : () {
              callbacks.onContinueReading?.call();
              prepareAndOpen(data.continueReading!.bookId);
            },
      onDeleteBook: removalOperation == null
          ? null
          : (book) async {
              await callbacks.onDeleteBook?.call(book);
              readerCoordinator.invalidate(book.id);
              await removalOperation.removeBook(book.id);
            },
      onSetBookPrivate: visibilityChanger == null
          ? null
          : (book) async {
              await callbacks.onSetBookPrivate?.call(book);
              controller.beginRemoval(book.id);
              try {
                await visibilityChanger.setBookVisibility(book.id, LibraryVisibility.private);
                controller.commitRemoval(book.id);
              } on Object {
                controller.rollbackRemoval(book.id);
                rethrow;
              }
            },
      onPrivacyLibraryRequested: onPrivacyLibraryRequested == null
          ? callbacks.onPrivacyLibraryRequested
          : () {
              callbacks.onPrivacyLibraryRequested?.call();
              onPrivacyLibraryRequested!();
            },
      onReadingHistory: onReadingHistoryRequested == null
          ? callbacks.onReadingHistory
          : () {
              callbacks.onReadingHistory?.call();
              onReadingHistoryRequested!();
            },
      onManageSources: onManageSourcesRequested == null
          ? callbacks.onManageSources
          : () {
              callbacks.onManageSources?.call();
              onManageSourcesRequested!();
            },
    );
    return _LibraryTerminalFrameSignal(
      startup: startup,
      child: _ShelfReaderLifecycleHost(
        warmBookIds: <String>[if (data.continueReading case final current?) current.bookId, for (final book in data.books.take(2)) book.id],
        contentGeneration: state.overview!,
        coordinator: readerCoordinator,
        child: LibraryHomeShell(
          data: data,
          initialLayoutMode: initialLayoutMode,
          onLayoutModeChanged: (LibraryHomeLayoutMode mode) => settings.set(AppSettingKeys.homeLayoutMode, mode.settingValue),
          callbacks: resolvedCallbacks,
          preparingBookId: readerLaunch.status == ShelfReaderPreparationStatus.preparing ? readerLaunch.bookId : null,
          isRefreshing: state.status == LibraryPageStatus.refreshing,
          onRefresh: controller.refresh,
          onToggleTheme: () {
            themeModeScope.onToggleTheme(Theme.of(context).brightness);
          },
          errorNotice: state.hasFailure ? _LibraryErrorCard(error: state.error!, onRetry: controller.refresh, hasRetainedData: true) : null,
        ),
      ),
    );
  }
}

PluginContentSummary _libraryDetailPreview(LibraryItemSummary? item, LibraryBookListItemViewData book) {
  final latestTitle = item?.latestChapterTitle;
  return PluginContentSummary(
    id: item?.coverRemoteContentId ?? book.id,
    title: item?.title ?? book.title,
    contentKind: PluginContentKind.novel,
    author: item?.author,
    url: item?.sourceUrl,
    coverUrl: item?.coverUrl ?? book.coverUrl,
    coverBytes: item?.coverBytes ?? book.coverBytes,
    description: item?.description,
    language: item?.language,
    status: switch (item?.statusLabel) {
      '连载' => PluginContentStatus.ongoing,
      '已完结' => PluginContentStatus.completed,
      '暂停更新' => PluginContentStatus.hiatus,
      _ => PluginContentStatus.unknown,
    },
    access: switch (item?.accessCode) {
      'free' => PluginAccessKind.free,
      'paid' => PluginAccessKind.paid,
      'mixed' => PluginAccessKind.mixed,
      _ => PluginAccessKind.unknown,
    },
    wordCount: item?.wordCount,
    chapterCount: item?.chapterCount,
    publishedAt: item?.publishedAt,
    updatedAt: item?.updatedAt,
    latestChapter: latestTitle == null
        ? null
        : PluginLatestChapter(
            id: item?.latestChapterId,
            title: latestTitle,
            url: item?.latestChapterUrl,
            updatedAt: item?.latestChapterUpdatedAt,
          ),
    categories: item?.categories ?? const <String>[],
    tags: item?.tags ?? const <String>[],
    attributes: <PluginContentAttribute>[
      for (final attribute in item?.attributes ?? const <LibraryItemSummaryAttribute>[])
        PluginContentAttribute(key: attribute.key, label: attribute.label, value: attribute.value),
    ],
  );
}

final class _LibraryTerminalFrameSignal extends StatefulWidget {
  const _LibraryTerminalFrameSignal({required this.startup, required this.child, this.resultState = 'ready'});

  final AppStartupController startup;
  final Widget child;
  final String resultState;

  @override
  State<_LibraryTerminalFrameSignal> createState() => _LibraryTerminalFrameSignalState();
}

final class _LibraryTerminalFrameSignalState extends State<_LibraryTerminalFrameSignal> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.startup.signalLibraryTerminalFrame(resultState: widget.resultState);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Bridges app lifecycle and memory pressure to the process-local warm LRU.
class _ShelfReaderLifecycleHost extends StatefulWidget {
  const _ShelfReaderLifecycleHost({
    required this.warmBookIds,
    required this.contentGeneration,
    required this.coordinator,
    required this.child,
  });

  final List<String> warmBookIds;
  final Object contentGeneration;
  final ShelfReaderLaunchCoordinator coordinator;
  final Widget child;

  @override
  State<_ShelfReaderLifecycleHost> createState() => _ShelfReaderLifecycleHostState();
}

class _ShelfReaderLifecycleHostState extends State<_ShelfReaderLifecycleHost> with WidgetsBindingObserver {
  String _warmSignature = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scheduleWarm();
  }

  @override
  void didUpdateWidget(covariant _ShelfReaderLifecycleHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.contentGeneration, widget.contentGeneration)) {
      widget.coordinator.clearWarmCache();
      _warmSignature = '';
    }
    _scheduleWarm();
  }

  void _scheduleWarm() {
    final signature = widget.warmBookIds.join('\u0000');
    if (signature == _warmSignature) return;
    _warmSignature = signature;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.coordinator.warm(widget.warmBookIds));
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached || state == AppLifecycleState.hidden) {
      widget.coordinator.clearWarmCache();
    }
  }

  @override
  void didHaveMemoryPressure() {
    widget.coordinator.clearWarmCache();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _LibraryLoadingState extends StatelessWidget {
  const _LibraryLoadingState({required this.showAnimation});

  final bool showAnimation;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: showAnimation
            ? const AppLoadingState(label: '正在加载书架', message: '正在加载书架')
            : Semantics(label: '正在加载书架', child: const SizedBox.shrink()),
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
  const _LibraryErrorCard({required this.error, required this.onRetry, this.hasRetainedData = false});

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
              Text(_errorTitle(error), style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onErrorContainer)),
              const SizedBox(height: AppSpacing.compact),
              Text(_errorDescription(error), style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onErrorContainer)),
              if (hasRetainedData) ...<Widget>[
                const SizedBox(height: AppSpacing.compact),
                Text('已保留上次成功加载的数据。', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onErrorContainer)),
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
