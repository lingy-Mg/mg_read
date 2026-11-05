/// 隐私书架页面。
///
/// 职责：
/// - 展示被设置为隐私的书籍。
/// - 提供取消隐私和删除操作，并保持本地书架状态即时更新。
/// - 以隐私图标标识底部首页目的地的当前模式。
///
/// 注意：
/// - 业务持久化由书架 application adapter 负责。
/// - 页面操作必须通过显式回调和稳定的书籍 ID 执行。
/// - 空状态与列表共用可刷新滚动区；操作反馈不随最后一项移除而消失。
/// - 封面模糊和未读角标遵循全局书架设置，列表条目按需构建。
///
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/library/application/library_book_remover.dart';
import 'package:mg_read/features/library/application/library_book_visibility_changer.dart';
import 'package:mg_read/features/library/application/library_catalog_refresh_coordinator.dart';
import 'package:mg_read/features/library/application/library_page_controller.dart';
import 'package:mg_read/features/library/application/library_page_state.dart';
import 'package:mg_read/features/library/presentation/library_book_list_view_data.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_list.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_list_action.dart';
import 'package:mg_read/features/library/presentation/widgets/bookshelf_removal_confirmation.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_bottom_navigation.dart';
import 'package:mg_read/shared/presentation/widgets/app_loading_state.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

const _restoreBookAction = LibraryBookListAction(id: 'restore-normal', label: '取消隐私');
const _deleteBookAction = LibraryBookListAction(id: 'delete', label: '删除');

/// The privacy-only bookshelf reached from the library's privacy entry.
class PrivateLibraryPage extends ConsumerWidget {
  const PrivateLibraryPage({
    required this.onBackRequested,
    required this.onDestinationRequested,
    required this.onReaderRequested,
    super.key,
  });

  final VoidCallback onBackRequested;
  final ValueChanged<AppNavigationDestination> onDestinationRequested;
  final ValueChanged<String> onReaderRequested;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final LibraryPageState state = ref.watch(privateLibraryPageControllerProvider);
    final PrivateLibraryPageController controller = ref.read(privateLibraryPageControllerProvider.notifier);
    final LibraryBookRemover? remover = ref.read(libraryBookRemoverProvider);
    final LibraryBookVisibilityChanger? visibilityChanger = ref.read(libraryBookVisibilityChangerProvider);
    final LibraryCatalogRefreshCoordinator? catalogRefreshCoordinator = ref.read(libraryCatalogRefreshCoordinatorProvider);
    final overview = state.overview;
    if (catalogRefreshCoordinator != null && overview != null) {
      final List<String> bookIds = overview.items.map((item) => item.id).toList(growable: false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        unawaited(
          catalogRefreshCoordinator.maybeRefresh(
            bookIds: bookIds,
            onChanged: (changedBookIds) async {
              if (!context.mounted) return;
              ref.read(libraryCatalogChangeProvider.notifier).publish(changedBookIds);
              await controller.silentRefresh();
            },
          ),
        );
      });
    }

    return Scaffold(
      extendBody: true,
      body: SafeArea(
        bottom: false,
        child: AppSecondaryPageContent(
          child: Column(
            children: <Widget>[
              AppSecondaryPageTopBar(
                title: '隐私书架',
                onBack: () {
                  unawaited(ref.read(libraryPageControllerProvider.notifier).refresh());
                  onBackRequested();
                },
                backButtonKey: const Key('private-library-back'),
              ),
              Expanded(
                child: _PrivateLibraryBody(
                  state: state,
                  controller: controller,
                  remover: remover,
                  visibilityChanger: visibilityChanger,
                  onReaderRequested: onReaderRequested,
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: AppBottomNavigation(
          selected: AppNavigationDestination.home,
          iconOverrides: const <AppNavigationDestination, AppNavigationIconOverride>{
            AppNavigationDestination.home: AppNavigationIconOverride(
              icon: Icons.visibility_off_outlined,
              selectedIcon: Icons.visibility_off_rounded,
            ),
          },
          onSelected: (destination) {
            if (destination == AppNavigationDestination.home) {
              unawaited(ref.read(libraryPageControllerProvider.notifier).refresh());
            }
            onDestinationRequested(destination);
          },
        ),
      ),
    );
  }
}

class _PrivateLibraryBody extends ConsumerStatefulWidget {
  const _PrivateLibraryBody({
    required this.state,
    required this.controller,
    required this.remover,
    required this.visibilityChanger,
    required this.onReaderRequested,
  });

  final LibraryPageState state;
  final PrivateLibraryPageController controller;
  final LibraryBookRemover? remover;
  final LibraryBookVisibilityChanger? visibilityChanger;
  final ValueChanged<String> onReaderRequested;

  @override
  ConsumerState<_PrivateLibraryBody> createState() => _PrivateLibraryBodyState();
}

class _PrivateLibraryBodyState extends ConsumerState<_PrivateLibraryBody> {
  String? _feedback;

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    ref.watch(appSettingsStatusProvider);
    final settings = ref.read(appSettingsProvider);
    final books = state.overview == null
        ? const <LibraryBookListItemViewData>[]
        : LibraryHomeViewData.fromLocalOverview(
            state.overview!,
            blurredBookIds: settings.get(AppSettingKeys.blurredCoverBookIds),
            showUnreadBadges: settings.get(AppSettingKeys.bookshelfUnreadBadgeEnabled),
          ).books;
    final actions = <LibraryBookListAction>[
      if (widget.visibilityChanger != null) _restoreBookAction,
      if (widget.remover != null) _deleteBookAction,
    ];
    return RefreshIndicator(
      onRefresh: widget.controller.refresh,
      child: CustomScrollView(
        key: const Key('private-library-content'),
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: <Widget>[
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              AppSpacing.compactPagePadding,
              AppSpacing.compact,
              AppSpacing.compactPagePadding,
              AppSpacing.bottomNavigationContentBottomPadding + MediaQuery.viewPaddingOf(context).bottom,
            ),
            sliver: SliverMainAxisGroup(
              slivers: <Widget>[
                if (_feedback != null || (state.hasFailure && state.hasRetainedData))
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.compact),
                      child: Column(
                        children: <Widget>[
                          if (_feedback != null)
                            _PrivateLibraryFeedback(message: _feedback!, onDismiss: () => setState(() => _feedback = null)),
                          if (state.hasFailure && state.hasRetainedData)
                            _PrivateLibraryFeedback(message: '刷新失败，仍显示上次加载的内容。', onRetry: () => unawaited(widget.controller.refresh())),
                        ],
                      ),
                    ),
                  ),
                if (state.status == LibraryPageStatus.initialLoading)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: AppLoadingState(label: '正在加载隐私书架', message: '正在加载隐私书架'),
                  )
                else if (state.overview == null)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: _PrivateLibraryFailure(error: state.error!, onRetry: widget.controller.refresh),
                  )
                else if (books.isEmpty)
                  const SliverFillRemaining(hasScrollBody: false, child: _PrivateLibraryEmpty())
                else
                  LibraryBookSliverList(
                    books: books,
                    onOpenBook: (book) => widget.onReaderRequested(book.id),
                    actions: actions,
                    onBookAction: _handleAction,
                    presentation: LibraryBookListPresentation.shelf,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _handleAction(LibraryBookListItemViewData book, LibraryBookListAction action) {
    switch (action.id) {
      case 'restore-normal':
        final changer = widget.visibilityChanger;
        if (changer != null) unawaited(_restoreBook(book, changer));
        return;
      case 'delete':
        final remover = widget.remover;
        if (remover != null) unawaited(_confirmAndDelete(book, remover));
        return;
    }
  }

  Future<void> _restoreBook(LibraryBookListItemViewData book, LibraryBookVisibilityChanger changer) async {
    final controller = widget.controller;
    final normalController = ref.read(libraryPageControllerProvider.notifier);
    controller.beginRemoval(book.id);
    try {
      await changer.setBookVisibility(book.id, LibraryVisibility.normal);
      controller.commitRemoval(book.id);
      unawaited(normalController.refresh());
      if (!mounted) return;
      setState(() => _feedback = '已取消《${book.title}》的隐私设置');
    } on Object {
      controller.rollbackRemoval(book.id);
      if (!mounted) return;
      setState(() => _feedback = '取消隐私未能完成，请稍后刷新。');
    }
  }

  Future<void> _confirmAndDelete(LibraryBookListItemViewData book, LibraryBookRemover remover) async {
    final confirmed = await showBookshelfRemovalConfirmation(context, title: book.title);
    if (!mounted || !confirmed) return;
    widget.controller.beginRemoval(book.id);
    try {
      await remover.removeBook(book.id);
      widget.controller.commitRemoval(book.id);
      if (!mounted) return;
      setState(() => _feedback = '已从书架删除《${book.title}》');
    } on Object {
      widget.controller.rollbackRemoval(book.id);
      if (!mounted) return;
      setState(() => _feedback = '删除操作未能完成，请稍后刷新。');
    }
  }
}

class _PrivateLibraryEmpty extends StatelessWidget {
  const _PrivateLibraryEmpty();

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return Center(
      child: Semantics(
        container: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.visibility_off_outlined, size: 40, color: tokens.mutedText),
            const SizedBox(height: AppSpacing.regular),
            Text('暂无隐私内容', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.unit),
            Text(
              '在首页通过条目的更多菜单或侧滑操作设为隐私，小说、漫画、音频和视频都会显示在这里。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
            ),
          ],
        ),
      ),
    );
  }
}

class _PrivateLibraryFailure extends StatelessWidget {
  const _PrivateLibraryFailure({required this.error, required this.onRetry});

  final AppError error;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(AppSpacing.section),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Text('暂时无法加载隐私书架'),
          const SizedBox(height: AppSpacing.compact),
          Text(error.code.wireValue),
          const SizedBox(height: AppSpacing.comfortable),
          FilledButton(onPressed: () => unawaited(onRetry()), child: const Text('重试')),
        ],
      ),
    ),
  );
}

class _PrivateLibraryFeedback extends StatelessWidget {
  const _PrivateLibraryFeedback({required this.message, this.onDismiss, this.onRetry});

  final String message;
  final VoidCallback? onDismiss;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return Semantics(
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.accentSoft,
          borderRadius: AppRadii.control,
          border: Border.all(color: tokens.accent),
        ),
        child: Padding(
          padding: const EdgeInsets.only(
            left: AppSpacing.regular,
            top: AppSpacing.compact,
            right: AppSpacing.compact,
            bottom: AppSpacing.compact,
          ),
          child: Row(
            children: <Widget>[
              Icon(Icons.info_outline_rounded, color: tokens.accent),
              const SizedBox(width: AppSpacing.compact),
              Expanded(child: Text(message)),
              if (onRetry != null) IconButton(tooltip: '重试刷新', onPressed: onRetry, icon: const Icon(Icons.refresh_rounded)),
              if (onDismiss != null) IconButton(tooltip: '关闭提示', onPressed: onDismiss, icon: const Icon(Icons.close_rounded)),
            ],
          ),
        ),
      ),
    );
  }
}
