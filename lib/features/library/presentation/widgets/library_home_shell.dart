import 'package:flutter/material.dart';

import 'package:mg_read/app/app_strings.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_update_tile.dart';
import 'package:mg_read/features/library/presentation/widgets/library_continue_reading_card.dart';
import 'package:mg_read/features/library/presentation/widgets/library_home_controls.dart';
import 'package:mg_read/features/library/presentation/widgets/library_source_manager_card.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_bottom_navigation.dart';

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
              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: AppSpacing.mobileContentMaxWidth,
                  ),
                  child: RefreshIndicator(
                    onRefresh: widget.onRefresh,
                    child: Scrollbar(
                      controller: _scrollController,
                      child: ListView(
                        key: const Key('library-home-content'),
                        controller: _scrollController,
                        primary: false,
                        padding: EdgeInsets.fromLTRB(
                          AppSpacing.compactPagePadding,
                          AppSpacing.homeContentTopPadding,
                          AppSpacing.compactPagePadding,
                          AppSpacing.page,
                        ),
                        physics: const AlwaysScrollableScrollPhysics(),
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
                              label: AppStrings.libraryRefreshingLabel,
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
                          KeyedSubtree(
                            key: const Key('library-mobile-layout'),
                            child: _buildCompactContent(context),
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

  Widget _buildCompactContent(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _buildReadingSurface(context),
        const SizedBox(height: AppSpacing.comfortable),
        _buildLibraryList(context),
        const SizedBox(height: AppSpacing.sourceManagerGap),
        _buildSourceManager(),
      ],
    );
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
    final List<LibraryBookUpdateViewData> books = _visibleBooks;
    final AppThemeTokens tokens = AppThemeTokens.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
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
        if (books.isEmpty)
          _NoMatchingBooks(tokens: tokens)
        else
          ...List<Widget>.generate(books.length, (int index) {
            final LibraryBookUpdateViewData book = books[index];
            return Column(
              children: <Widget>[
                LibraryBookUpdateTile(
                  data: book,
                  onOpen: () => _handleOpenBook(book),
                  onMore: () => _handleBookMore(book),
                ),
                if (index < books.length - 1)
                  Padding(
                    padding: const EdgeInsets.only(
                      left:
                          AppSpacing.listCoverWidth +
                          AppSpacing.compact +
                          AppSpacing.unit,
                    ),
                    child: Divider(
                      height: 1,
                      thickness: 1,
                      color: tokens.divider,
                    ),
                  ),
              ],
            );
          }),
      ],
    );
  }

  Widget _buildSourceManager() {
    return LibrarySourceManagerCard(
      sourceCount: widget.data.availableSourceCount,
      onPressed: _handleManageSources,
    );
  }

  List<LibraryBookUpdateViewData> get _visibleBooks {
    final Iterable<LibraryBookUpdateViewData> sectionBooks = widget.data.books;
    return sectionBooks.where(_matchesFilter).toList(growable: false);
  }

  bool _matchesFilter(LibraryBookUpdateViewData book) {
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

  void _handleOpenBook(LibraryBookUpdateViewData book) {
    final ValueChanged<LibraryBookUpdateViewData>? callback =
        widget.callbacks.onOpenBook;
    if (callback != null) {
      callback(book);
      return;
    }
    _showUnavailableMessage();
  }

  void _handleBookMore(LibraryBookUpdateViewData book) {
    final ValueChanged<LibraryBookUpdateViewData>? callback =
        widget.callbacks.onBookMore;
    if (callback != null) {
      callback(book);
      return;
    }
    _showUnavailableMessage();
  }

  void _handleManageSources() {
    _invoke(widget.callbacks.onManageSources);
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
      _actionFeedback = AppStrings.actionUnavailableMessage;
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
    return Row(
      children: <Widget>[
        Expanded(
          child: Semantics(
            header: true,
            child: Text(
              AppStrings.libraryTitle,
              style: theme.textTheme.displaySmall?.copyWith(
                fontSize: 26,
                fontWeight: FontWeight.w600,
                height: 1.15,
                letterSpacing: -0.3,
              ),
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.compact),
        _LibraryTopBarAction(
          tooltip: AppStrings.searchActionLabel,
          onPressed: onSearch,
          icon: Icons.search_rounded,
        ),
        if (toggleTheme != null)
          Padding(
            padding: const EdgeInsets.only(left: AppSpacing.compact),
            child: _LibraryTopBarAction(
              key: const Key('theme-mode-toggle'),
              tooltip: theme.brightness == Brightness.dark
                  ? AppStrings.switchToLightThemeLabel
                  : AppStrings.switchToDarkThemeLabel,
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
              child: const Text(AppStrings.readingHistoryLabel),
            ),
            MenuItemButton(
              onPressed: onManageSources,
              child: const Text(AppStrings.manageSourcesActionLabel),
            ),
          ],
          builder:
              (BuildContext context, MenuController controller, Widget? child) {
                return _LibraryTopBarAction(
                  tooltip: AppStrings.moreActionsLabel,
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
                tooltip: AppStrings.dismissLabel,
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
                  Text(
                    AppStrings.noReadingProgressTitle,
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: AppSpacing.compact),
                  Text(
                    AppStrings.noReadingProgressDescription,
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
          AppStrings.noMatchingBooksLabel,
          style: theme.textTheme.bodyLarge?.copyWith(color: tokens.mutedText),
        ),
      ),
    );
  }
}
