/// 首页书架展示壳。
///
/// 职责：
/// - 组合首页书架布局、筛选、刷新与用户反馈。
/// - 在保留当前 Sliver 滚动身份的前提下编排删除展示过渡。
/// - 将底部首页图标长按映射为隐私书架扩散过渡。
///
/// 注意：
/// - 不在 build() 中执行持久化；删除由显式回调在动画后提交。
/// - 当前滚动控制器只由本壳持有并在销毁时释放。
/// - 分区筛选局部更新；顶部封面背景覆盖状态栏，交互内容仍按安全区下沿布局。
///
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/presentation/library_book_list_view_data.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_grid.dart';
import 'package:mg_read/features/library/presentation/widgets/bookshelf_removal_confirmation.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_list.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_list_action.dart';
import 'package:mg_read/features/library/presentation/widgets/library_continue_reading_card.dart';
import 'package:mg_read/features/library/presentation/widgets/library_home_controls.dart';
import 'package:mg_read/features/library/presentation/widgets/library_home_top_bar.dart';
import 'package:mg_read/features/library/presentation/widgets/library_home_top_visual.dart';
import 'package:mg_read/features/library/presentation/widgets/private_library_reveal.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_bottom_navigation.dart';
import 'package:mg_read/shared/presentation/widgets/app_page_backdrop.dart';

const _deleteBookAction = LibraryBookListAction(id: 'delete', label: '删除');
const _setBookPrivateAction = LibraryBookListAction(id: 'set-private', label: '隐私');
const _refreshBookAction = LibraryBookListAction(id: 'refresh', label: '刷新');
const _toggleBookCoverBlurAction = LibraryBookListAction(id: 'toggle-cover-blur', label: '模糊封面', labelBuilder: _coverBlurActionLabel);

String _coverBlurActionLabel(LibraryBookListItemViewData book) => book.isCoverBlurred ? '取消模糊封面' : '模糊封面';

/// The responsive, presentation-only app shell for the library landing page.
class LibraryHomeShell extends StatefulWidget {
  /// Creates a library home shell from immutable [data] and explicit actions.
  const LibraryHomeShell({
    required this.data,
    required this.onRefresh,
    required this.isRefreshing,
    this.initialLayoutMode = LibraryHomeLayoutMode.list,
    this.onLayoutModeChanged,
    this.showLoading = false,
    this.preparingBookId,
    this.errorNotice,
    this.onToggleTheme,
    this.callbacks = const LibraryHomeCallbacks(),
    super.key,
  });

  final LibraryHomeViewData data;
  final Future<void> Function() onRefresh;
  final bool isRefreshing;
  final LibraryHomeLayoutMode initialLayoutMode;
  final Future<void> Function(LibraryHomeLayoutMode mode)? onLayoutModeChanged;

  /// Hides shelf content while app startup is resolving the real library.
  final bool showLoading;
  final String? preparingBookId;
  final Widget? errorNotice;

  /// Temporarily switches the app's light/dark mode when provided.
  final VoidCallback? onToggleTheme;

  final LibraryHomeCallbacks callbacks;

  @override
  State<LibraryHomeShell> createState() => _LibraryHomeShellState();
}

class _LibraryHomeShellState extends State<LibraryHomeShell> {
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _bottomNavigationKey = GlobalKey();
  final ValueNotifier<({LibraryHomeSection section, LibraryStatusFilter filter})> _selection =
      ValueNotifier<({LibraryHomeSection section, LibraryStatusFilter filter})>((
        section: LibraryHomeSection.recentUpdates,
        filter: LibraryStatusFilter.all,
      ));
  String? _actionFeedback;
  double _contentOpacity = 1;
  final Set<String> _removingBookIds = <String>{};
  final Set<String> _refreshingBookIds = <String>{};
  final Set<String> _coverBlurTogglingBookIds = <String>{};
  late LibraryHomeLayoutMode _layoutMode;
  bool _layoutModeChangePending = false;
  bool _privacyRevealActive = false;

  @override
  void initState() {
    super.initState();
    _layoutMode = widget.initialLayoutMode;
  }

  @override
  void didUpdateWidget(covariant LibraryHomeShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_layoutModeChangePending && oldWidget.initialLayoutMode != widget.initialLayoutMode) {
      _layoutMode = widget.initialLayoutMode;
    }
    if (oldWidget.isRefreshing && !widget.isRefreshing && !identical(oldWidget.data, widget.data)) {
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
    _selection.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AppPageBackdrop(
        style: AppPageBackdropStyle.home,
        child: FocusTraversalGroup(
          policy: OrderedTraversalPolicy(),
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final bool useWidePagePadding = constraints.maxWidth >= AppSpacing.compactLayoutBreakpoint;
              final double pagePadding = useWidePagePadding ? AppSpacing.widePagePadding : AppSpacing.compactPagePadding;
              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: AppSpacing.contentMaxWidth),
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
                          _buildTopSliver(context, pagePadding),
                          SliverPadding(
                            padding: EdgeInsets.fromLTRB(pagePadding, AppSpacing.comfortable, pagePadding, AppSpacing.page),
                            sliver: _buildBodySlivers(context),
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
          key: _bottomNavigationKey,
          selected: AppNavigationDestination.home,
          onSelected: _handleDestinationSelected,
          onLongPressed: _handleDestinationLongPressed,
        ),
      ),
    );
  }

  Widget _buildTopSliver(BuildContext context, double pagePadding) {
    return SliverToBoxAdapter(
      child: LibraryHomeTopVisual(
        continueReading: widget.data.continueReading,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            pagePadding,
            MediaQuery.paddingOf(context).top + AppSpacing.pageHeaderTopPaddingFor(context),
            pagePadding,
            AppSpacing.comfortable,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              RepaintBoundary(
                key: const Key('library-stable-header'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Stack(
                      children: <Widget>[
                        if (!widget.showLoading && !_isFirstRunEmpty)
                          AnimatedOpacity(
                            opacity: _contentOpacity,
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOut,
                            child: KeyedSubtree(
                              key: const Key('library-mobile-layout'),
                              child: RepaintBoundary(
                                key: const Key('library-stable-reading-surface'),
                                child: _buildReadingSurface(context),
                              ),
                            ),
                          ),
                        LibraryHomeTopBar(
                          onSearch: _handleSearch,
                          onToggleTheme: widget.onToggleTheme,
                          onReadingHistory: _handleReadingHistory,
                          onManageSources: _handleManageSources,
                          onPrivacyLibrary: _handlePrivacyLibrary,
                          layoutMode: _layoutMode,
                          onLayoutModeToggle: _handleLayoutModeToggle,
                        ),
                      ],
                    ),
                    if (widget.isRefreshing) ...<Widget>[
                      const SizedBox(height: AppSpacing.regular),
                      Semantics(label: '正在刷新书架', child: const LinearProgressIndicator()),
                    ],
                    if (widget.errorNotice != null) ...<Widget>[const SizedBox(height: AppSpacing.comfortable), widget.errorNotice!],
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
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBodySlivers(BuildContext context) {
    return SliverMainAxisGroup(
      slivers: <Widget>[
        if (widget.showLoading)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(top: AppSpacing.comfortable),
              child: Center(child: CircularProgressIndicator()),
            ),
          )
        else ...<Widget>[
          ValueListenableBuilder<({LibraryHomeSection section, LibraryStatusFilter filter})>(
            valueListenable: _selection,
            builder: (BuildContext context, selection, Widget? child) {
              final List<LibraryBookListItemViewData> books = _visibleBooks(selection.filter);
              return SliverMainAxisGroup(
                slivers: <Widget>[
                  SliverAnimatedOpacity(
                    opacity: _contentOpacity,
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOut,
                    sliver: SliverToBoxAdapter(child: _buildLibraryListHeader(selection)),
                  ),
                  SliverAnimatedOpacity(
                    opacity: _contentOpacity,
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOut,
                    sliver: books.isEmpty
                        ? SliverToBoxAdapter(
                            child: _isFirstRunEmpty && selection.section == LibraryHomeSection.recentUpdates
                                ? _NoRecentUpdatesCard(onDiscover: _handleDiscover)
                                : _NoMatchingBooks(tokens: AppThemeTokens.of(context)),
                          )
                        : _buildBookCollection(books: books, section: selection.section),
                  ),
                ],
              );
            },
          ),
        ],
      ],
    );
  }

  bool get _isFirstRunEmpty => !widget.data.isPresentationFixture && widget.data.continueReading == null && widget.data.books.isEmpty;

  Widget _buildReadingSurface(BuildContext context) {
    final LibraryContinueReadingViewData? continueReading = widget.data.continueReading;
    if (continueReading == null) {
      return const _NoReadingProgressCard();
    }
    return LibraryContinueReadingCard(
      data: continueReading,
      showBackdrop: false,
      isPreparing: widget.preparingBookId == continueReading.bookId,
      onContinueReading: _handleContinueReading,
    );
  }

  LibraryBookListPresentation _listPresentation(LibraryHomeSection section) =>
      section == LibraryHomeSection.recentUpdates ? LibraryBookListPresentation.recentUpdates : LibraryBookListPresentation.shelf;

  Widget _buildBookCollection({required List<LibraryBookListItemViewData> books, required LibraryHomeSection section}) {
    if (_layoutMode == LibraryHomeLayoutMode.card) {
      return LibraryBookSliverGrid(
        books: books,
        onOpenBook: _handleOpenBook,
        onBookLongPress: _handleBookLongPress,
        onBookMore: _handleBookMore,
        actions: _bookActions,
        onBookAction: _handleBookAction,
        preparingBookId: widget.preparingBookId,
        removingBookIds: _removingBookIds,
        refreshingBookIds: _refreshingBookIds,
      );
    }
    return LibraryBookSliverList(
      books: books,
      onOpenBook: _handleOpenBook,
      onBookLongPress: _handleBookLongPress,
      onBookMore: _handleBookMore,
      actions: _bookActions,
      onBookAction: _handleBookAction,
      presentation: _listPresentation(section),
      preparingBookId: widget.preparingBookId,
      removingBookIds: _removingBookIds,
      refreshingBookIds: _refreshingBookIds,
    );
  }

  List<LibraryBookListAction> get _bookActions => <LibraryBookListAction>[
    if (widget.callbacks.onRefreshBook != null) _refreshBookAction,
    if (widget.callbacks.onSetBookPrivate != null) _setBookPrivateAction,
    if (widget.callbacks.onToggleBookCoverBlur != null) _toggleBookCoverBlurAction,
    if (widget.callbacks.onDeleteBook != null) _deleteBookAction,
  ];

  Widget _buildLibraryListHeader(({LibraryHomeSection section, LibraryStatusFilter filter}) selection) {
    return Column(
      children: <Widget>[
        Row(
          key: const Key('library-list-heading-row'),
          children: <Widget>[
            LibrarySectionNavigation(
              selected: selection.section,
              onSelected: (LibraryHomeSection section) {
                if (section == _selection.value.section) return;
                _selection.value = (section: section, filter: _selection.value.filter);
              },
            ),
            const SizedBox(width: AppSpacing.compact),
            Expanded(
              child: LibraryStatusFilterBar(
                selected: selection.filter,
                onSelected: (LibraryStatusFilter filter) {
                  if (filter == _selection.value.filter) return;
                  _selection.value = (section: _selection.value.section, filter: filter);
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.compact),
      ],
    );
  }

  List<LibraryBookListItemViewData> _visibleBooks(LibraryStatusFilter filter) {
    final Iterable<LibraryBookListItemViewData> sectionBooks = widget.data.books;
    return sectionBooks.where((LibraryBookListItemViewData book) => _matchesFilter(book, filter)).toList(growable: false);
  }

  bool _matchesFilter(LibraryBookListItemViewData book, LibraryStatusFilter filter) {
    return switch (filter) {
      LibraryStatusFilter.all => true,
      LibraryStatusFilter.ongoing => book.status == LibraryBookStatus.ongoing,
      LibraryStatusFilter.completed => book.status == LibraryBookStatus.completed,
      LibraryStatusFilter.local => book.status == LibraryBookStatus.local,
    };
  }

  void _handleSearch() {
    _invoke(widget.callbacks.onSearch);
  }

  Future<void> _handleLayoutModeToggle() async {
    if (_layoutModeChangePending) return;
    final LibraryHomeLayoutMode previousMode = _layoutMode;
    final LibraryHomeLayoutMode nextMode = previousMode == LibraryHomeLayoutMode.list
        ? LibraryHomeLayoutMode.card
        : LibraryHomeLayoutMode.list;
    setState(() {
      _layoutMode = nextMode;
      _layoutModeChangePending = true;
      _actionFeedback = null;
    });
    try {
      await widget.onLayoutModeChanged?.call(nextMode);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _layoutMode = previousMode;
        _actionFeedback = '首页布局偏好保存失败，已恢复原模式。';
      });
    } finally {
      if (mounted) {
        setState(() {
          _layoutModeChangePending = false;
        });
      }
    }
  }

  void _handleReadingHistory() {
    _invoke(widget.callbacks.onReadingHistory);
  }

  void _handleContinueReading() {
    _invoke(widget.callbacks.onContinueReading);
  }

  void _handleOpenBook(LibraryBookListItemViewData book) {
    final ValueChanged<LibraryBookListItemViewData>? callback = widget.callbacks.onOpenBook;
    if (callback != null) {
      callback(book);
      return;
    }
    _showUnavailableMessage();
  }

  void _handleBookMore(LibraryBookListItemViewData book) {
    final ValueChanged<LibraryBookListItemViewData>? callback = widget.callbacks.onBookMore;
    if (callback != null) {
      callback(book);
      return;
    }
    _showUnavailableMessage();
  }

  void _handleBookLongPress(LibraryBookListItemViewData book) {
    final ValueChanged<LibraryBookListItemViewData>? callback = widget.callbacks.onBookLongPress;
    if (callback != null) {
      callback(book);
      return;
    }
    _showUnavailableMessage();
  }

  void _handleBookAction(LibraryBookListItemViewData book, LibraryBookListAction action) {
    switch (action.id) {
      case 'refresh':
        final refreshBook = widget.callbacks.onRefreshBook;
        if (refreshBook != null) {
          unawaited(_refreshBook(book, refreshBook));
          return;
        }
        break;
      case 'delete':
        final deleteBook = widget.callbacks.onDeleteBook;
        if (deleteBook != null) {
          unawaited(_confirmAndDeleteBook(book, deleteBook));
          return;
        }
        break;
      case 'set-private':
        final setPrivate = widget.callbacks.onSetBookPrivate;
        if (setPrivate != null) {
          unawaited(_setBookPrivate(book, setPrivate));
          return;
        }
        break;
      case 'toggle-cover-blur':
        final toggleCoverBlur = widget.callbacks.onToggleBookCoverBlur;
        if (toggleCoverBlur != null) {
          unawaited(_toggleBookCoverBlur(book, toggleCoverBlur));
          return;
        }
        break;
    }
    _showUnavailableMessage();
  }

  Future<void> _toggleBookCoverBlur(
    LibraryBookListItemViewData book,
    Future<void> Function(LibraryBookListItemViewData) toggleCoverBlur,
  ) async {
    if (!_coverBlurTogglingBookIds.add(book.id)) return;
    try {
      await toggleCoverBlur(book);
      if (!mounted) return;
      final bool isBlurred = !book.isCoverBlurred;
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(behavior: SnackBarBehavior.floating, content: Text(isBlurred ? '已模糊《${book.title}》的封面' : '已取消《${book.title}》的封面模糊')),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _actionFeedback = '封面隐私设置未能完成，请稍后重试。');
    } finally {
      _coverBlurTogglingBookIds.remove(book.id);
    }
  }

  Future<void> _refreshBook(LibraryBookListItemViewData book, Future<void> Function(LibraryBookListItemViewData) refreshBook) async {
    if (!_refreshingBookIds.add(book.id)) return;
    setState(() {});
    try {
      await refreshBook(book);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(behavior: SnackBarBehavior.floating, content: Text('《${book.title}》已刷新')));
    } on Object {
      if (!mounted) return;
      setState(() => _actionFeedback = '刷新书籍失败，请稍后重试。');
    } finally {
      if (mounted) {
        setState(() {
          _refreshingBookIds.remove(book.id);
        });
      }
    }
  }

  Future<void> _setBookPrivate(LibraryBookListItemViewData book, Future<void> Function(LibraryBookListItemViewData) setPrivate) async {
    if (!_removingBookIds.add(book.id)) return;
    setState(() {});
    final Duration transitionDuration = MediaQuery.disableAnimationsOf(context) ? Duration.zero : AppMotion.destinationTransition;
    await Future<void>.delayed(transitionDuration);
    if (!mounted) return;

    try {
      await setPrivate(book);
      if (!mounted) return;
      setState(() {
        _removingBookIds.remove(book.id);
      });
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(behavior: SnackBarBehavior.floating, content: Text('已将《${book.title}》设为隐私书籍')));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _removingBookIds.remove(book.id);
        _actionFeedback = '隐私设置未能完成，请稍后刷新。';
      });
    }
  }

  Future<void> _confirmAndDeleteBook(
    LibraryBookListItemViewData book,
    Future<void> Function(LibraryBookListItemViewData) deleteBook,
  ) async {
    final confirmed = await showBookshelfRemovalConfirmation(context, title: book.title);
    if (!mounted || !confirmed) return;

    if (!_removingBookIds.add(book.id)) return;
    setState(() {});
    final Duration transitionDuration = MediaQuery.disableAnimationsOf(context) ? Duration.zero : AppMotion.destinationTransition;
    await Future<void>.delayed(transitionDuration);
    if (!mounted) return;

    try {
      await deleteBook(book);
      if (!mounted) return;
      setState(() {
        _removingBookIds.remove(book.id);
      });
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(behavior: SnackBarBehavior.floating, content: Text('已从书架删除《${book.title}》')));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _removingBookIds.remove(book.id);
        _actionFeedback = '删除操作未能完成，请稍后刷新。';
      });
    }
  }

  void _handleManageSources() {
    _invoke(widget.callbacks.onManageSources);
  }

  void _handlePrivacyLibrary() {
    _invoke(widget.callbacks.onPrivacyLibraryRequested);
  }

  void _handleDestinationLongPressed(AppNavigationDestination destination) {
    if (destination != AppNavigationDestination.home || widget.callbacks.onPrivacyLibraryRequested == null) return;
    unawaited(_showPrivacyReveal());
  }

  Future<void> _showPrivacyReveal() async {
    if (_privacyRevealActive || !mounted) return;
    _privacyRevealActive = true;
    try {
      final RenderBox? navigationBox = _bottomNavigationKey.currentContext?.findRenderObject() as RenderBox?;
      final Size screenSize = MediaQuery.sizeOf(context);
      final double bottomInset = MediaQuery.paddingOf(context).bottom;
      final Offset origin =
          navigationBox?.localToGlobal(
            Offset(navigationBox.size.width / (AppNavigationDestination.values.length * 2), navigationBox.size.height / 2),
          ) ??
          Offset(
            screenSize.width / (AppNavigationDestination.values.length * 2),
            screenSize.height - bottomInset - AppSpacing.bottomNavigationHeight / 2,
          );
      await showPrivateLibraryReveal(
        context: context,
        globalOrigin: origin,
        onCovered: () {
          if (mounted) _handlePrivacyLibrary();
        },
      );
    } finally {
      _privacyRevealActive = false;
    }
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
    final ValueChanged<AppNavigationDestination>? callback = widget.callbacks.onNavigationSelected;
    if (callback != null) {
      callback(destination);
      return;
    }
    if (destination == AppNavigationDestination.profile) {
      final VoidCallback? onProfileSelected = widget.callbacks.onProfileSelected;
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
                child: Text(message, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onPrimaryContainer)),
              ),
              IconButton(tooltip: '关闭提示', onPressed: onDismiss, icon: const Icon(Icons.close_rounded)),
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
                  Text('阅读进度接入本地资料后会显示在这里。', style: theme.textTheme.bodyMedium?.copyWith(color: tokens.mutedText)),
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
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.section, vertical: AppSpacing.page),
          child: Column(
            children: <Widget>[
              SizedBox(
                width: 144,
                height: 116,
                child: ExcludeSemantics(child: Image.asset('assets/illustrations/library_empty_updates.png', fit: BoxFit.contain)),
              ),
              const SizedBox(height: AppSpacing.compact),
              Text('暂无更新内容', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: AppSpacing.compact),
              Text(
                '添加数据源后，你关注的作品会显示在这里',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
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
        child: Text('没有符合当前筛选条件的书籍', style: theme.textTheme.bodyLarge?.copyWith(color: tokens.mutedText)),
      ),
    );
  }
}
