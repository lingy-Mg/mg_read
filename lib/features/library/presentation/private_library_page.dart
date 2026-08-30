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
///
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/library/application/library_book_remover.dart';
import 'package:mg_read/features/library/application/library_book_visibility_changer.dart';
import 'package:mg_read/features/library/application/library_page_controller.dart';
import 'package:mg_read/features/library/application/library_page_state.dart';
import 'package:mg_read/features/library/presentation/library_book_list_view_data.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_list.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_list_action.dart';
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

    return Scaffold(
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
    if (state.status == LibraryPageStatus.initialLoading) {
      return const AppLoadingState(label: '正在加载隐私书架', message: '正在加载隐私书架');
    }
    if (state.overview == null) {
      return _PrivateLibraryFailure(error: state.error!, onRetry: widget.controller.refresh);
    }
    final books = LibraryHomeViewData.fromLocalOverview(state.overview!).books;
    if (books.isEmpty) return const _PrivateLibraryEmpty();
    final actions = <LibraryBookListAction>[
      if (widget.visibilityChanger != null) _restoreBookAction,
      if (widget.remover != null) _deleteBookAction,
    ];
    return RefreshIndicator(
      onRefresh: widget.controller.refresh,
      child: ListView(
        key: const Key('private-library-content'),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.compactPagePadding,
          AppSpacing.compact,
          AppSpacing.compactPagePadding,
          AppSpacing.page,
        ),
        children: <Widget>[
          if (_feedback != null) ...<Widget>[
            _PrivateLibraryFeedback(message: _feedback!, onDismiss: () => setState(() => _feedback = null)),
            const SizedBox(height: AppSpacing.compact),
          ],
          LibraryBookList(
            books: books,
            onOpenBook: (book) => widget.onReaderRequested(book.id),
            actions: actions,
            onBookAction: _handleAction,
            presentation: LibraryBookListPresentation.shelf,
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
    widget.controller.beginRemoval(book.id);
    try {
      await changer.setBookVisibility(book.id, LibraryVisibility.normal);
      widget.controller.commitRemoval(book.id);
      unawaited(ref.read(libraryPageControllerProvider.notifier).refresh());
      if (!mounted) return;
      setState(() => _feedback = '已取消《${book.title}》的隐私设置');
    } on Object {
      widget.controller.rollbackRemoval(book.id);
      if (!mounted) return;
      setState(() => _feedback = '取消隐私未能完成，请稍后刷新。');
    }
  }

  Future<void> _confirmAndDelete(LibraryBookListItemViewData book, LibraryBookRemover remover) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除书籍'),
        content: Text('确定要从书架删除《${book.title}》吗？'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('删除')),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
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
        label: '暂无隐私书籍',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.visibility_off_outlined, size: 40, color: tokens.mutedText),
            const SizedBox(height: AppSpacing.regular),
            Text('暂无隐私书籍', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.unit),
            Text(
              '在首页书籍的侧滑操作中设置隐私后，会显示在这里。',
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
  const _PrivateLibraryFeedback({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return DecoratedBox(
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
            IconButton(tooltip: '关闭提示', onPressed: onDismiss, icon: const Icon(Icons.close_rounded)),
          ],
        ),
      ),
    );
  }
}
