/// 阅读记录二级页面。
///
/// 职责：
/// - 展示本地阅读、观看和收听记录，并按内容类型交给对应宿主。
/// - 复用设置页的二级页面顶部栏、安全区和返回行为。
///
/// 注意：
/// - 只消费 Library Page 的已投影状态，不直接访问 persistence。
/// - 页面不显示主导航栏；媒体入口复用书架投影，保存与续播由宿主负责。
/// - 媒体准备期间防止重复打开，离开页面后不得继续导航。
///
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/library/application/library_book_detail_launcher.dart';
import 'package:mg_read/features/library/presentation/library_page.dart';
import 'package:mg_read/features/library/presentation/library_book_list_view_data.dart';
import 'package:mg_read/features/library/presentation/library_media_entry_data.dart';
import 'package:mg_read/features/media/application/source_audio_playback_service.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focus_region.dart';
import 'package:mg_read/features/library/application/library_page_controller.dart';
import 'package:mg_read/features/library/application/library_page_state.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_list.dart';
import 'package:mg_read/shared/presentation/widgets/app_loading_state.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

/// Displays the locally persisted reading history.
class ReadingHistoryPage extends ConsumerStatefulWidget {
  const ReadingHistoryPage({
    required this.onBackRequested,
    required this.onReaderRequested,
    this.onAudioChapterRequested,
    this.onVideoEpisodeRequested,
    super.key,
  });

  final VoidCallback onBackRequested;
  final ValueChanged<String> onReaderRequested;
  final LibraryAudioChapterRequested? onAudioChapterRequested;
  final LibraryVideoEpisodeRequested? onVideoEpisodeRequested;

  @override
  ConsumerState<ReadingHistoryPage> createState() => _ReadingHistoryPageState();
}

class _ReadingHistoryPageState extends ConsumerState<ReadingHistoryPage> {
  bool _opening = false;

  Future<void> _open(LibraryBookListItemViewData book) async {
    if (_opening) return;
    if (book.contentKind == ContentKind.novel || book.contentKind == ContentKind.manga) {
      widget.onReaderRequested(book.id);
      return;
    }
    _opening = true;
    try {
      final item = ref.read(libraryPageControllerProvider).overview?.items.where((item) => item.id == book.id).firstOrNull;
      if (book.contentKind == ContentKind.audio &&
          ref
              .read(sourceAudioPlaybackServiceProvider.notifier)
              .revealExistingForShelfItem(libraryItemId: book.id, contentId: item?.coverRemoteContentId ?? book.id)) {
        return;
      }
      var entry = immediateLibraryMediaEntry(item, book);
      if (entry == null) {
        final launcher = ref.read(libraryBookDetailLauncherProvider);
        if (launcher == null) throw StateError('历史内容暂时无法打开');
        final seed = await launcher.load(book.id);
        entry = persistedLibraryMediaEntry(detail: seed.initialDetail, catalog: seed.initialCatalog, book: book);
      }
      if (!mounted || ModalRoute.of(context)?.isCurrent == false) return;
      if (book.contentKind == ContentKind.video) {
        final callback = widget.onVideoEpisodeRequested;
        if (callback == null) throw StateError('视频播放器暂不可用');
        await callback(detail: entry.detail, firstCatalogPage: entry.catalog, chapter: entry.chapter, libraryItemId: book.id);
      } else {
        final callback = widget.onAudioChapterRequested;
        if (callback == null) throw StateError('音频播放器暂不可用');
        await callback(
          detail: entry.detail,
          firstCatalogPage: entry.catalog,
          chapter: entry.chapter,
          pluginVersion: item?.coverPluginVersion ?? book.coverRequest?.pluginVersion ?? 'unknown',
          libraryItemId: book.id,
        );
      }
      if (mounted) unawaited(ref.read(libraryPageControllerProvider.notifier).refresh());
    } on Object catch (error) {
      if (mounted && ModalRoute.of(context)?.isCurrent != false) {
        final failure = AppError.fromUnknown(error);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(failure.detail ?? '无法打开历史内容，请检查数据源后重试。')));
      }
    } finally {
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final LibraryPageState state = ref.watch(libraryPageControllerProvider);
    final LibraryPageController controller = ref.read(libraryPageControllerProvider.notifier);
    return TvFocusRegion(
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: AppSecondaryPageContent(
            child: Column(
              children: <Widget>[
                AppSecondaryPageTopBar(
                  key: const Key('reading-history-top-bar'),
                  title: '观看与阅读记录',
                  onBack: widget.onBackRequested,
                  backButtonKey: const Key('reading-history-back'),
                ),
                Expanded(
                  child: _ReadingHistoryBody(state: state, onRefresh: controller.refresh, onOpen: (book) => unawaited(_open(book))),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ReadingHistoryBody extends StatelessWidget {
  const _ReadingHistoryBody({required this.state, required this.onRefresh, required this.onOpen});

  final LibraryPageState state;
  final Future<void> Function() onRefresh;
  final ValueChanged<LibraryBookListItemViewData> onOpen;

  @override
  Widget build(BuildContext context) {
    if (state.status == LibraryPageStatus.initialLoading) {
      return const AppLoadingState(label: '正在加载观看与阅读记录', message: '正在加载观看与阅读记录');
    }
    if (state.overview == null) {
      return Center(child: Text('观看与阅读记录暂不可用，请返回首页后重试。', style: Theme.of(context).textTheme.bodyMedium));
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
            LibraryBookList(books: books, onOpenBook: onOpen, presentation: LibraryBookListPresentation.readingHistory),
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
          label: '暂无观看与阅读记录',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.history_rounded, size: 44, color: tokens.mutedText),
              const SizedBox(height: AppSpacing.regular),
              Text('暂无观看与阅读记录', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: AppSpacing.unit),
              Text('开始阅读、观看或收听后，最近使用的内容会显示在这里。', style: theme.textTheme.bodyMedium?.copyWith(color: tokens.mutedText)),
            ],
          ),
        ),
      ),
    );
  }
}
