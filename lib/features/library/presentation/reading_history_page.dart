/// 阅读记录二级页面。
///
/// 职责：
/// - 展示应用本地已保存阅读进度对应的书籍列表。
/// - 复用设置页的二级页面顶部栏、安全区和返回行为。
///
/// 注意：
/// - 只消费 Library Page 的已投影状态，不直接访问 persistence。
/// - 页面不显示主导航栏；阅读条目打开行为由路由层提供。
///
/// TODO:
/// - 无。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/application/library_page_controller.dart';
import 'package:mg_read/features/library/application/library_page_state.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_list.dart';
import 'package:mg_read/shared/presentation/widgets/app_loading_state.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

/// Displays the locally persisted reading history.
class ReadingHistoryPage extends ConsumerWidget {
  const ReadingHistoryPage({required this.onBackRequested, required this.onReaderRequested, super.key});

  final VoidCallback onBackRequested;
  final ValueChanged<String> onReaderRequested;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final LibraryPageState state = ref.watch(libraryPageControllerProvider);
    final LibraryPageController controller = ref.read(libraryPageControllerProvider.notifier);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: AppSecondaryPageContent(
          child: Column(
            children: <Widget>[
              AppSecondaryPageTopBar(
                key: const Key('reading-history-top-bar'),
                title: '阅读记录',
                onBack: onBackRequested,
                backButtonKey: const Key('reading-history-back'),
              ),
              Expanded(
                child: _ReadingHistoryBody(state: state, onRefresh: controller.refresh, onReaderRequested: onReaderRequested),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReadingHistoryBody extends StatelessWidget {
  const _ReadingHistoryBody({required this.state, required this.onRefresh, required this.onReaderRequested});

  final LibraryPageState state;
  final Future<void> Function() onRefresh;
  final ValueChanged<String> onReaderRequested;

  @override
  Widget build(BuildContext context) {
    if (state.status == LibraryPageStatus.initialLoading) {
      return const AppLoadingState(label: '正在加载阅读记录', message: '正在加载阅读记录');
    }
    if (state.overview == null) {
      return Center(child: Text('阅读记录暂不可用，请返回首页后重试。', style: Theme.of(context).textTheme.bodyMedium));
    }

    final books = LibraryHomeViewData.fromReadingHistory(state.overview!).books;
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        key: const Key('reading-history-content'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.compactPagePadding,
          AppSpacing.compact,
          AppSpacing.compactPagePadding,
          AppSpacing.page,
        ),
        children: <Widget>[
          if (books.isEmpty)
            const _ReadingHistoryEmptyState()
          else
            LibraryBookList(
              books: books,
              onOpenBook: (book) => onReaderRequested(book.id),
              presentation: LibraryBookListPresentation.readingHistory,
            ),
        ],
      ),
    );
  }
}

class _ReadingHistoryEmptyState extends StatelessWidget {
  const _ReadingHistoryEmptyState();

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final ThemeData theme = Theme.of(context);
    return SizedBox(
      height: 280,
      child: Center(
        child: Semantics(
          container: true,
          label: '暂无阅读记录',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.history_rounded, size: 44, color: tokens.mutedText),
              const SizedBox(height: AppSpacing.regular),
              Text('暂无阅读记录', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: AppSpacing.unit),
              Text('开始阅读后，最近打开的书籍会显示在这里。', style: theme.textTheme.bodyMedium?.copyWith(color: tokens.mutedText)),
            ],
          ),
        ),
      ),
    );
  }
}
