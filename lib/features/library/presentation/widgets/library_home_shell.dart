import 'dart:async';

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/presentation/library_book_list_view_data.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_list.dart';
import 'package:mg_read/features/library/presentation/widgets/library_continue_reading_card.dart';
import 'package:mg_read/features/library/presentation/widgets/library_home_controls.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_bottom_navigation.dart';
import 'package:mg_read/shared/presentation/widgets/app_page_title.dart';

/// The responsive, presentation-only app shell for the library landing page.
class LibraryHomeShell extends StatefulWidget {
  /// Creates a library home shell from immutable [data] and explicit actions.
  const LibraryHomeShell({
    required this.data,
    required this.onRefresh,
    required this.isRefreshing,
    this.errorNotice,
    this.onToggleTheme,
    this.callbacks = const LibraryHomeCallbacks(),
    super.key,
  });

  final LibraryHomeViewData data;
  final Future<void> Function() onRefresh;
  final bool isRefreshing;
  final Widget? errorNotice;

  /// Temporarily switches the app's light/dark mode when provided.
  final VoidCallback? onToggleTheme;

  final LibraryHomeCallbacks callbacks;

  @override
  State<LibraryHomeShell> createState() => _LibraryHomeShellState();
}

class _LibraryHomeShellState extends State<LibraryHomeShell> {
  final ScrollController _scrollController = ScrollController();
  LibraryHomeSection _section = LibraryHomeSection.recentUpdates;
  LibraryStatusFilter _filter = LibraryStatusFilter.all;
  String? _actionFeedback;
  double _contentOpacity = 1;

  @override
  void didUpdateWidget(covariant LibraryHomeShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isRefreshing &&
        !widget.isRefreshing &&
        !identical(oldWidget.data, widget.data)) {
      _contentOpacity = 0.4;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _contentOpacity = 1;
        });
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: FocusTraversalGroup(
          policy: OrderedTraversalPolicy(),
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final bool useWidePagePadding =
                  constraints.maxWidth >= AppSpacing.compactLayoutBreakpoint;
              final double pagePadding = useWidePagePadding
                  ? AppSpacing.widePagePadding
                  : AppSpacing.compactPagePadding;
              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: AppSpacing.contentMaxWidth,
                  ),
                  child: RefreshIndicator(
                    onRefresh: widget.onRefresh,
                    child: Scrollbar(
                      controller: _scrollController,
                      child: CustomScrollView(
                        key: const Key('library-home-content'),
                        controller: _scrollController,
                        primary: false,
                        physics: const AlwaysScrollableScrollPhysics(),
                        slivers: <Widget>[
                          SliverPadding(
                            padding: EdgeInsets.fromLTRB(
                              pagePadding,
                              AppSpacing.pageHeaderTopPadding,
                              pagePadding,
                              AppSpacing.page,
                            ),
                            sliver: _buildContentSlivers(context),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: AppBottomNavigation(
          selected: AppNavigationDestination.home,
          onSelected: _handleDestinationSelected,
        ),
      ),
    );
  }

  Widget _buildContentSlivers(BuildContext context) {
    final List<LibraryBookListItemViewData> books = _visibleBooks;
    return SliverMainAxisGroup(
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              LibraryHomeTopBar(
                onSearch: _handleSearch,
                onToggleTheme: widget.onToggleTheme,
                onReadingHistory: _handleReadingHistory,
                onManageSources: _handleManageSources,
              ),
              if (widget.isRefreshing) ...<Widget>[
                const SizedBox(height: AppSpacing.regular),
                Semantics(
                  label: '正在刷新书架',
                  child: const LinearProgressIndicator(),
                ),
              ],
              if (widget.errorNotice != null) ...<Widget>[
                const SizedBox(height: AppSpacing.comfortable),
                widget.errorNotice!,
              ],
              if (_actionFeedback != null) ...<Widget>[
                const SizedBox(height: AppSpacing.comfortable),
                _ActionFeedbackBanner(
                  message: _actionFeedback!,
                  onDismiss: () {
                    setState(() {
                      _actionFeedback = null;
                    });
                  },
                ),
              ],
              const SizedBox(height: AppSpacing.regular),
            ],
          ),
        ),
        if (books.isEmpty)
          SliverAnimatedOpacity(
            opacity: _contentOpacity,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            sliver: SliverToBoxAdapter(
              child: KeyedSubtree(
                key: const Key('library-mobile-layout'),
                child: _buildCompactContent(context),
              ),
            ),
          )
        else ...<Widget>[
          SliverAnimatedOpacity(
            opacity: _contentOpacity,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            sliver: SliverToBoxAdapter(
              child: KeyedSubtree(
                key: const Key('library-mobile-layout'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _buildReadingSurface(context),
                    const SizedBox(height: AppSpacing.comfortable),
                    _buildLibraryListHeader(),
                  ],
                ),
              ),
            ),
          ),
          SliverAnimatedOpacity(
            opacity: _contentOpacity,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            sliver: LibraryBookSliverList(
              books: books,
              onOpenBook: _handleOpenBook,
              onBookMore: _handleBookMore,
              presentation: _listPresentation,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildCompactContent(BuildContext context) {
    if (_isFirstRunEmpty) {
      return _buildFirstRunContent(context);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildReadingSurface(context),
        const SizedBox(height: AppSpacing.comfortable),
        _buildLibraryList(context),
      ],
    );
  }

  bool get _isFirstRunEmpty =>
      !widget.data.isPresentationFixture &&
      widget.data.continueReading == null &&
      widget.data.books.isEmpty;

  Widget _buildFirstRunContent(BuildContext context) {
    return _buildLibraryList(context);
  }

  Widget _buildReadingSurface(BuildContext context) {
    final LibraryContinueReadingViewData? continueReading =
        widget.data.continueReading;
    if (continueReading == null) {
      return const _NoReadingProgressCard();
    }
    return LibraryContinueReadingCard(
      data: continueReading,
      onContinueReading: _handleContinueReading,
      onReadingHistory: _handleReadingHistory,
    );
  }

  Widget _buildLibraryList(BuildContext context) {
    final List<LibraryBookListItemViewData> books = _visibleBooks;
    final AppThemeTokens tokens = AppThemeTokens.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildLibraryListHeader(),
        if (books.isEmpty)
          _section == LibraryHomeSection.recentUpdates && _isFirstRunEmpty
              ? _NoRecentUpdatesCard(onDiscover: _handleDiscover)
              : _NoMatchingBooks(tokens: tokens)
        else
          LibraryBookList(
            books: books,
            onOpenBook: _handleOpenBook,
            onBookMore: _handleBookMore,
            presentation: _listPresentation,
          ),
      ],
    );
  }

  LibraryBookListPresentation get _listPresentation =>
      _section == LibraryHomeSection.recentUpdates
      ? LibraryBookListPresentation.recentUpdates
      : LibraryBookListPresentation.shelf;

  Widget _buildLibraryListHeader() {
    return Column(
      children: <Widget>[
        Row(
          key: const Key('library-list-heading-row'),
          children: <Widget>[
            LibrarySectionNavigation(
              selected: _section,
              onSelected: (LibraryHomeSection section) {
                setState(() {
                  _section = section;
                });
              },
            ),
            const SizedBox(width: AppSpacing.compact),
            Expanded(
              child: LibraryStatusFilterBar(
                selected: _filter,
                onSelected: (LibraryStatusFilter filter) {
                  setState(() {
                    _filter = filter;
                  });
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.compact),
      ],
    );
  }

  List<LibraryBookListItemViewData> get _visibleBooks {
    final Iterable<LibraryBookListItemViewData> sectionBooks =
        widget.data.books;
    return sectionBooks.where(_matchesFilter).toList(growable: false);
  }

  bool _matchesFilter(LibraryBookListItemViewData book) {
    return switch (_filter) {
      LibraryStatusFilter.all => true,
      LibraryStatusFilter.ongoing => book.status == LibraryBookStatus.ongoing,
      LibraryStatusFilter.completed =>
        book.status == LibraryBookStatus.completed,
      LibraryStatusFilter.local => book.status == LibraryBookStatus.local,
    };
  }

  void _handleSearch() {
    _invoke(widget.callbacks.onSearch);
  }

  void _handleReadingHistory() {
    _invoke(widget.callbacks.onReadingHistory);
  }

  void _handleContinueReading() {
    _invoke(widget.callbacks.onContinueReading);
  }

  void _handleOpenBook(LibraryBookListItemViewData book) {
    final ValueChanged<LibraryBookListItemViewData>? callback =
        widget.callbacks.onOpenBook;
    if (callback != null) {
      callback(book);
      return;
    }
    _showUnavailableMessage();
  }

  void _handleBookMore(LibraryBookListItemViewData book) {
    final Future<void> Function(LibraryBookListItemViewData)? deleteBook =
        widget.callbacks.onDeleteBook;
    if (deleteBook != null) {
      unawaited(_confirmAndDeleteBook(book, deleteBook));
      return;
    }
    final ValueChanged<LibraryBookListItemViewData>? callback =
        widget.callbacks.onBookMore;
    if (callback != null) {
      callback(book);
      return;
    }
    _showUnavailableMessage();
  }

  Future<void> _confirmAndDeleteBook(
    LibraryBookListItemViewData book,
    Future<void> Function(LibraryBookListItemViewData) deleteBook,
  ) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('删除书籍'),
        content: Text('确定要从书架删除《${book.title}》吗？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;

    try {
      await deleteBook(book);
      if (!mounted) return;
      setState(() {
        _actionFeedback = '已从书架删除《${book.title}》';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _actionFeedback = '删除操作未能完成，请稍后刷新。';
      });
    }
  }

  void _handleManageSources() {
    _invoke(widget.callbacks.onManageSources);
  }

  void _handleDiscover() {
    final callback = widget.callbacks.onDiscover;
    if (callback != null) {
      callback();
      return;
    }
    _handleDestinationSelected(AppNavigationDestination.discover);
  }

  void _handleDestinationSelected(AppNavigationDestination destination) {
    if (destination == AppNavigationDestination.home) {
      return;
    }
    final ValueChanged<AppNavigationDestination>? callback =
        widget.callbacks.onNavigationSelected;
    if (callback != null) {
      callback(destination);
      return;
    }
    if (destination == AppNavigationDestination.profile) {
      final VoidCallback? onProfileSelected =
          widget.callbacks.onProfileSelected;
      if (onProfileSelected != null) {
        onProfileSelected();
        return;
      }
    }
    if (destination != AppNavigationDestination.home) {
      _showUnavailableMessage();
    }
  }

  void _invoke(VoidCallback? callback) {
    if (callback != null) {
      callback();
      return;
    }
    _showUnavailableMessage();
  }

  void _showUnavailableMessage() {
    setState(() {
      _actionFeedback = '此操作尚未接入真实数据，可由后续功能替换。';
    });
  }
}

/// Title and top-level actions shared by the library home layouts.
class LibraryHomeTopBar extends StatelessWidget {
  /// Creates the top title, search action, and overflow menu.
  const LibraryHomeTopBar({
    required this.onSearch,
    required this.onReadingHistory,
    required this.onManageSources,
    this.onToggleTheme,
    super.key,
  });

  final VoidCallback onSearch;
  final VoidCallback? onToggleTheme;
  final VoidCallback onReadingHistory;
  final VoidCallback onManageSources;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final VoidCallback? toggleTheme = onToggleTheme;
    return SizedBox(
      height: AppSpacing.pageHeaderHeight,
      child: Row(
        children: <Widget>[
          const Expanded(child: AppPageTitle(title: '首页')),
          const SizedBox(width: AppSpacing.compact),
          _LibraryTopBarAction(
            tooltip: '搜索书籍',
            onPressed: onSearch,
            icon: Icons.search_rounded,
          ),
          if (AppTheme.darkModeEnabled && toggleTheme != null)
            Padding(
              padding: const EdgeInsets.only(left: AppSpacing.compact),
              child: _LibraryTopBarAction(
                key: const Key('theme-mode-toggle'),
                tooltip: theme.brightness == Brightness.dark
                    ? '切换至浅色模式'
                    : '切换至深色模式',
                onPressed: toggleTheme,
                icon: theme.brightness == Brightness.dark
                    ? Icons.light_mode_outlined
                    : Icons.dark_mode_outlined,
              ),
            ),
          const SizedBox(width: AppSpacing.compact),
          MenuAnchor(
            menuChildren: <Widget>[
              MenuItemButton(
                onPressed: onReadingHistory,
                child: const Text('阅读记录'),
              ),
              MenuItemButton(
                onPressed: onManageSources,
                child: const Text('管理数据源'),
              ),
            ],
            builder:
                (
                  BuildContext context,
                  MenuController controller,
                  Widget? child,
                ) {
                  return _LibraryTopBarAction(
                    tooltip: '更多操作',
                    onPressed: () {
                      if (controller.isOpen) {
                        controller.close();
                      } else {
                        controller.open();
                      }
                    },
                    icon: Icons.more_vert_rounded,
                  );
                },
          ),
        ],
      ),
    );
  }
}

class _LibraryTopBarAction extends StatelessWidget {
  const _LibraryTopBarAction({
    required this.tooltip,
    required this.onPressed,
    required this.icon,
    super.key,
  });

  final String tooltip;
  final VoidCallback onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Semantics(
      button: true,
      label: tooltip,
      onTap: onPressed,
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: Colors.transparent,
          child: InkResponse(
            onTap: onPressed,
            excludeFromSemantics: true,
            radius: AppSpacing.topBarActionSize / 2,
            child: SizedBox(
              width: AppSpacing.topBarActionSize,
              height: AppSpacing.topBarActionSize,
              child: Center(
                child: Icon(
                  icon,
                  size: AppSpacing.topBarActionIconSize,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionFeedbackBanner extends StatelessWidget {
  const _ActionFeedbackBanner({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Semantics(
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.accentSoft,
          border: Border.all(color: tokens.accent),
          borderRadius: AppRadii.control,
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
              Expanded(
                child: Text(
                  message,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
              IconButton(
                tooltip: '关闭提示',
                onPressed: onDismiss,
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoReadingProgressCard extends StatelessWidget {
  const _NoReadingProgressCard();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.featureSurface,
        border: Border.all(color: tokens.divider),
        borderRadius: AppRadii.card,
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.section),
        child: Row(
          children: <Widget>[
            Icon(Icons.menu_book_outlined, color: tokens.accent),
            const SizedBox(width: AppSpacing.regular),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('从书架开始阅读', style: theme.textTheme.titleMedium),
                  const SizedBox(height: AppSpacing.compact),
                  Text(
                    '阅读进度接入本地资料后会显示在这里。',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: tokens.mutedText,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoRecentUpdatesCard extends StatelessWidget {
  const _NoRecentUpdatesCard({required this.onDiscover});

  final VoidCallback onDiscover;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    return Semantics(
      liveRegion: true,
      label: '暂无更新内容',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.surface,
          border: Border.all(color: tokens.divider),
          borderRadius: AppRadii.surface,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.section,
            vertical: AppSpacing.page,
          ),
          child: Column(
            children: <Widget>[
              SizedBox(
                width: 144,
                height: 116,
                child: ExcludeSemantics(
                  child: Image.asset(
                    'assets/illustrations/library_empty_updates.png',
                    fit: BoxFit.contain,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.compact),
              Text(
                '暂无更新内容',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: AppSpacing.compact),
              Text(
                '添加书源后，你关注的作品会显示在这里',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: tokens.mutedText,
                ),
              ),
              const SizedBox(height: AppSpacing.comfortable),
              OutlinedButton(onPressed: onDiscover, child: const Text('去发现好书')),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoMatchingBooks extends StatelessWidget {
  const _NoMatchingBooks({required this.tokens});

  final AppThemeTokens tokens;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.section),
        child: Text(
          '没有符合当前筛选条件的书籍',
          style: theme.textTheme.bodyLarge?.copyWith(color: tokens.mutedText),
        ),
      ),
    );
  }
}
