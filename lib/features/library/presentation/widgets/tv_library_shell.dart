/// TV library surface: local filters, stable focus, remote actions and dialogs.
/// Data, playback, mutation and mode persistence are owned by the caller.
/// Refresh keeps the mounted shelf; destructive actions require confirmation.
/// Slivers decode covers only near the viewport and retain keyed focus on refresh.
library;

import 'package:flutter/material.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/presentation/library_book_list_view_data.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';
import 'package:mg_read/features/library/presentation/tv_library_data.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';
import 'tv_library_cards.dart';

class TvLibraryShell extends StatefulWidget {
  const TvLibraryShell({
    required this.data,
    required this.callbacks,
    required this.onPlay,
    required this.onDetail,
    required this.onRefresh,
    this.errorNotice,
    super.key,
  });
  final TvLibraryData data;
  final LibraryHomeCallbacks callbacks;
  final Future<void> Function(LibraryBookListItemViewData) onPlay;
  final Future<void> Function(LibraryBookListItemViewData) onDetail;
  final Future<void> Function() onRefresh;
  final Widget? errorNotice;

  @override
  State<TvLibraryShell> createState() => _TvLibraryShellState();
}

class _TvLibraryShellState extends State<TvLibraryShell> {
  TvLibraryFilter _filter = TvLibraryFilter.all;
  bool _busy = false;
  bool _dialogOpen = false;
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on Object {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('操作失败，请重试')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _select(TvLibraryFilter filter) {
    setState(() => _filter = filter);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Future<void> _more(TvLibraryEntry entry) async {
    if (_dialogOpen || _busy) return;
    _dialogOpen = true;
    final book = entry.book;
    try {
      final action = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(book.title),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _dialogAction(context, '播放', 'play', autofocus: true),
                _dialogAction(context, '查看详情', 'detail'),
                if (widget.callbacks.onRefreshBook != null) _dialogAction(context, '刷新内容', 'refresh'),
                if (widget.callbacks.onDeleteBook != null) _dialogAction(context, '移除收藏', 'remove'),
                _dialogAction(context, '取消', 'cancel'),
              ],
            ),
          ),
        ),
      );
      if (!mounted) return;
      switch (action) {
        case 'play':
          await _run(() => widget.onPlay(book));
        case 'detail':
          await _run(() => widget.onDetail(book));
        case 'refresh':
          await _run(() => widget.callbacks.onRefreshBook!(book));
        case 'remove':
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('移除收藏？'),
              content: Text('将《${book.title}》从收藏中移除。'),
              actions: [
                TextButton(autofocus: true, onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
                FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('移除')),
              ],
            ),
          );
          if (confirmed == true && mounted) await _run(() => widget.callbacks.onDeleteBook!(book));
        default:
          break;
      }
    } finally {
      _dialogOpen = false;
    }
  }

  Widget _dialogAction(BuildContext context, String label, String value, {bool autofocus = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: TvFocusable(
      autofocus: autofocus,
      onPressed: () => Navigator.pop(context, value),
      child: Text(label, style: Theme.of(context).textTheme.titleLarge),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final entries = widget.data.filtered(_filter);
    final hero = _filter == TvLibraryFilter.all ? widget.data.resume ?? entries.firstOrNull : null;
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    return PopScope<void>(
      canPop: _filter == TvLibraryFilter.all,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _select(TvLibraryFilter.all);
      },
      child: Scaffold(
        key: const Key('tv-library-home'),
        backgroundColor: tokens.pageBackground,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final margin = constraints.maxWidth >= 900 ? 40.0 : 16.0;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: margin, vertical: 12),
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: Text('MgRead TV', style: theme.textTheme.headlineSmall),
                        ),
                        _nav(
                          '首页',
                          'home',
                          () => _select(TvLibraryFilter.all),
                          selected: _filter == TvLibraryFilter.all,
                          autofocus: hero == null,
                        ),
                        _nav('电影', 'movies', () => _select(TvLibraryFilter.movies), selected: _filter == TvLibraryFilter.movies),
                        _nav('剧集', 'series', () => _select(TvLibraryFilter.series), selected: _filter == TvLibraryFilter.series),
                        _nav('搜索', 'search', () => widget.callbacks.onNavigationSelected?.call(AppNavigationDestination.search)),
                        _nav('发现', 'discover', () => widget.callbacks.onNavigationSelected?.call(AppNavigationDestination.discover)),
                        _nav('设置', 'settings', () => widget.callbacks.onNavigationSelected?.call(AppNavigationDestination.profile)),
                        _nav('普通 / TV', 'mode', () => TvModeScope.maybeOf(context)?.onChanged(false)),
                      ],
                    ),
                  ),
                  Expanded(
                    child: CustomScrollView(
                      controller: _scroll,
                      key: const PageStorageKey('tv-library-scroll'),
                      slivers: [
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(margin, 8, margin, 24),
                          sliver: SliverList.list(
                            children: [
                              ?widget.errorNotice,
                              if (hero != null) ...[
                                TvLibraryHero(
                                  entry: hero,
                                  onPlay: () => _run(() => widget.onPlay(hero.book)),
                                  onDetail: () => _run(() => widget.onDetail(hero.book)),
                                ),
                                const SizedBox(height: 24),
                              ],
                              Wrap(
                                spacing: 16,
                                runSpacing: 8,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Text(switch (_filter) {
                                    TvLibraryFilter.all => '我的影视',
                                    TvLibraryFilter.movies => '电影收藏',
                                    TvLibraryFilter.series => '剧集收藏',
                                    TvLibraryFilter.reading => '阅读与听书',
                                  }, style: theme.textTheme.headlineSmall),
                                  _nav(_busy ? '正在处理…' : '刷新收藏', 'refresh', () => _run(widget.onRefresh)),
                                  if (_filter != TvLibraryFilter.reading) _nav('全部影视', 'all', () => _select(TvLibraryFilter.all)),
                                ],
                              ),
                              const SizedBox(height: 18),
                              if (entries.isEmpty)
                                Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 40),
                                  child: Column(
                                    children: [
                                      Icon(Icons.video_library_outlined, size: 56, color: tokens.mutedText),
                                      const SizedBox(height: 16),
                                      Text(
                                        '暂无${_filter == TvLibraryFilter.reading ? '阅读内容' : '对应的影视收藏'}',
                                        style: theme.textTheme.titleLarge,
                                      ),
                                      const SizedBox(height: 12),
                                      Text(
                                        _filter == TvLibraryFilter.movies || _filter == TvLibraryFilter.series
                                            ? '只按来源标注的分类筛选，未分类内容请到“全部影视”查看。'
                                            : '通过搜索或发现找到内容后，加入收藏。',
                                        textAlign: TextAlign.center,
                                      ),
                                      const SizedBox(height: 20),
                                      _nav(
                                        '搜索内容',
                                        'empty-search',
                                        () => widget.callbacks.onNavigationSelected?.call(AppNavigationDestination.search),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                        if (entries.isNotEmpty)
                          SliverPadding(
                            padding: EdgeInsets.symmetric(horizontal: margin),
                            sliver: SliverLayoutBuilder(
                              builder: (context, shelf) {
                                final columns = (shelf.crossAxisExtent / 250).floor().clamp(1, 5);
                                final width = (shelf.crossAxisExtent - (columns - 1) * 20) / columns;
                                final indices = {for (var i = 0; i < entries.length; i++) entries[i].book.id: i};
                                return SliverGrid.builder(
                                  itemCount: entries.length,
                                  findChildIndexCallback: (key) => key is ValueKey<String> ? indices[key.value] : null,
                                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: columns,
                                    crossAxisSpacing: 20,
                                    mainAxisSpacing: 24,
                                    mainAxisExtent: (width - 12) * 9 / 16 + 160 * MediaQuery.textScalerOf(context).scale(1),
                                  ),
                                  itemBuilder: (context, index) {
                                    final entry = entries[index];
                                    return TvLibraryCard(
                                      key: ValueKey(entry.book.id),
                                      entry: entry,
                                      width: width,
                                      onOpen: () => _run(() => widget.onDetail(entry.book)),
                                      onMore: () => _more(entry),
                                    );
                                  },
                                );
                              },
                            ),
                          ),
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(margin, 0, margin, 24),
                          sliver: SliverList.list(
                            children: [
                              const SizedBox(height: 28),
                              Wrap(
                                spacing: 16,
                                runSpacing: 12,
                                children: [
                                  _nav(
                                    '阅读与听书',
                                    'reading',
                                    () => _select(TvLibraryFilter.reading),
                                    selected: _filter == TvLibraryFilter.reading,
                                  ),
                                  if (widget.callbacks.onManageSources != null) _nav('管理数据源', 'sources', widget.callbacks.onManageSources!),
                                  if (widget.callbacks.onReadingHistory != null)
                                    _nav('观看与阅读记录', 'history', widget.callbacks.onReadingHistory!),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Text(
                      '方向键 移动    OK 打开    菜单键 更多    返回键 返回',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyLarge?.copyWith(color: tokens.mutedText),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _nav(String text, String id, VoidCallback action, {bool selected = false, bool autofocus = false}) => TvFocusable(
    key: Key('tv-nav-$id'),
    selected: selected,
    autofocus: autofocus,
    onPressed: action,
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );
}
