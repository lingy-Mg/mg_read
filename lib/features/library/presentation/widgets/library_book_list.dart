/// 书架书籍列表。
///
/// 职责：
/// - 为首页、书架和阅读记录提供一致的普通与 Sliver 列表行。
/// - 保持长列表惰性构建，并承载条目菜单和原位置删除过渡。
///
/// 注意：
/// - 条目移除只改变局部展示高度，不替换父滚动容器或控制器。
/// - 业务持久化由调用方负责；本组件只转发不可变数据与动作。
///
/// TODO:
/// - 无。
library;

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/presentation/library_book_list_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_anchored_menu.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_cover.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_list_action.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_removal_transition.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_swipe_actions.dart';

typedef LibraryBookListActionSelected = void Function(LibraryBookListItemViewData book, LibraryBookListAction action);

/// Layout switches for the shared compact book-list design.
///
/// The presets keep recent updates, the shelf, and reading history on the same
/// visual grid. A consuming feature may create a value with only the switches
/// it needs instead of duplicating the row widget.
@immutable
final class LibraryBookListPresentation {
  /// Creates a configurable presentation of the shared book-list row.
  const LibraryBookListPresentation({
    this.showActivityLabel = true,
    this.showOverflowAction = true,
    this.showSwipeActions = false,
    this.showAttentionIndicator = false,
  });

  /// The compact row used by the recent-updates section.
  static const LibraryBookListPresentation recentUpdates = LibraryBookListPresentation(
    showOverflowAction: false,
    showSwipeActions: true,
    showAttentionIndicator: true,
  );

  /// The compact row used by the bookshelf section.
  static const LibraryBookListPresentation shelf = LibraryBookListPresentation(showSwipeActions: true);

  /// The compact row reserved for the reading-history surface.
  static const LibraryBookListPresentation readingHistory = LibraryBookListPresentation();

  final bool showActivityLabel;
  final bool showOverflowAction;
  final bool showSwipeActions;
  final bool showAttentionIndicator;

  /// Copies this layout while replacing selected visibility switches.
  LibraryBookListPresentation copyWith({
    bool? showActivityLabel,
    bool? showOverflowAction,
    bool? showSwipeActions,
    bool? showAttentionIndicator,
  }) {
    return LibraryBookListPresentation(
      showActivityLabel: showActivityLabel ?? this.showActivityLabel,
      showOverflowAction: showOverflowAction ?? this.showOverflowAction,
      showSwipeActions: showSwipeActions ?? this.showSwipeActions,
      showAttentionIndicator: showAttentionIndicator ?? this.showAttentionIndicator,
    );
  }
}

/// A reusable compact book list for recent updates, shelves, and history.
///
/// The list owns row spacing and dividers so every consuming screen keeps the
/// reference layout's cover, metadata, and trailing-control alignment.
class LibraryBookList extends StatelessWidget {
  /// Creates a book list from display-ready item data and explicit callbacks.
  LibraryBookList({
    required Iterable<LibraryBookListItemViewData> books,
    required this.onOpenBook,
    this.onBookLongPress,
    this.onBookMore,
    Iterable<LibraryBookListAction> actions = const <LibraryBookListAction>[],
    this.onBookAction,
    this.presentation = LibraryBookListPresentation.recentUpdates,
    this.showDividers = true,
    this.preparingBookId,
    Iterable<String> removingBookIds = const <String>[],
    super.key,
  }) : books = List<LibraryBookListItemViewData>.unmodifiable(books),
       actions = List<LibraryBookListAction>.unmodifiable(actions),
       removingBookIds = Set<String>.unmodifiable(removingBookIds);

  final List<LibraryBookListItemViewData> books;
  final ValueChanged<LibraryBookListItemViewData> onOpenBook;
  final ValueChanged<LibraryBookListItemViewData>? onBookLongPress;
  final ValueChanged<LibraryBookListItemViewData>? onBookMore;
  final List<LibraryBookListAction> actions;
  final LibraryBookListActionSelected? onBookAction;
  final LibraryBookListPresentation presentation;
  final bool showDividers;
  final String? preparingBookId;
  final Set<String> removingBookIds;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Column(
      children: List<Widget>.generate(
        books.length,
        (int index) => _LibraryBookListRow(
          book: books[index],
          onOpenBook: onOpenBook,
          onBookLongPress: onBookLongPress,
          onBookMore: onBookMore,
          actions: actions,
          onBookAction: onBookAction,
          presentation: presentation,
          showDivider: showDividers && index < books.length - 1,
          dividerColor: tokens.divider,
          isPreparing: books[index].id == preparingBookId,
          isRemoving: removingBookIds.contains(books[index].id),
        ),
      ),
    );
  }
}

/// A lazily built sliver version of [LibraryBookList].
///
/// It preserves the compact row visual contract while avoiding construction of
/// offscreen rows in long scrolling surfaces.
class LibraryBookSliverList extends StatelessWidget {
  /// Creates a sliver list from display-ready book rows and explicit callbacks.
  LibraryBookSliverList({
    required Iterable<LibraryBookListItemViewData> books,
    required this.onOpenBook,
    this.onBookLongPress,
    this.onBookMore,
    Iterable<LibraryBookListAction> actions = const <LibraryBookListAction>[],
    this.onBookAction,
    this.presentation = LibraryBookListPresentation.recentUpdates,
    this.showDividers = true,
    this.preparingBookId,
    Iterable<String> removingBookIds = const <String>[],
    super.key,
  }) : books = List<LibraryBookListItemViewData>.unmodifiable(books),
       actions = List<LibraryBookListAction>.unmodifiable(actions),
       removingBookIds = Set<String>.unmodifiable(removingBookIds);

  final List<LibraryBookListItemViewData> books;
  final ValueChanged<LibraryBookListItemViewData> onOpenBook;
  final ValueChanged<LibraryBookListItemViewData>? onBookLongPress;
  final ValueChanged<LibraryBookListItemViewData>? onBookMore;
  final List<LibraryBookListAction> actions;
  final LibraryBookListActionSelected? onBookAction;
  final LibraryBookListPresentation presentation;
  final bool showDividers;
  final String? preparingBookId;
  final Set<String> removingBookIds;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (BuildContext context, int index) => KeyedSubtree(
          key: ValueKey<String>(books[index].id),
          child: _LibraryBookListRow(
            book: books[index],
            onOpenBook: onOpenBook,
            onBookLongPress: onBookLongPress,
            onBookMore: onBookMore,
            actions: actions,
            onBookAction: onBookAction,
            presentation: presentation,
            showDivider: showDividers && index < books.length - 1,
            dividerColor: tokens.divider,
            isPreparing: books[index].id == preparingBookId,
            isRemoving: removingBookIds.contains(books[index].id),
          ),
        ),
        childCount: books.length,
      ),
    );
  }
}

class _LibraryBookListRow extends StatelessWidget {
  const _LibraryBookListRow({
    required this.book,
    required this.onOpenBook,
    required this.onBookLongPress,
    required this.onBookMore,
    required this.actions,
    required this.onBookAction,
    required this.presentation,
    required this.showDivider,
    required this.dividerColor,
    required this.isPreparing,
    required this.isRemoving,
  });

  final LibraryBookListItemViewData book;
  final ValueChanged<LibraryBookListItemViewData> onOpenBook;
  final ValueChanged<LibraryBookListItemViewData>? onBookLongPress;
  final ValueChanged<LibraryBookListItemViewData>? onBookMore;
  final List<LibraryBookListAction> actions;
  final LibraryBookListActionSelected? onBookAction;
  final LibraryBookListPresentation presentation;
  final bool showDivider;
  final Color dividerColor;
  final bool isPreparing;
  final bool isRemoving;

  @override
  Widget build(BuildContext context) {
    final Widget row = LibraryBookListItem(
      data: book,
      onOpen: () => onOpenBook(book),
      onLongPress: onBookLongPress == null ? null : () => onBookLongPress!(book),
      onMore: onBookMore == null ? null : () => onBookMore!(book),
      actions: actions,
      onAction: onBookAction == null ? null : (action) => onBookAction!(book, action),
      presentation: presentation,
      isPreparing: isPreparing,
    );
    final Widget interactiveRow = presentation.showSwipeActions && actions.isNotEmpty && onBookAction != null
        ? LibraryBookSwipeActions(actions: actions, onAction: (action) => onBookAction!(book, action), child: row)
        : row;
    return LibraryBookRemovalTransition(
      isRemoving: isRemoving,
      child: Column(
        children: <Widget>[
          interactiveRow,
          if (showDivider)
            Padding(
              padding: const EdgeInsets.only(left: AppSpacing.listCoverWidth + AppSpacing.compact + AppSpacing.unit),
              child: Divider(height: 1, thickness: 1, color: dividerColor),
            ),
        ],
      ),
    );
  }
}

/// A compact, touch-safe row shared by all library book lists.
class LibraryBookListItem extends StatelessWidget {
  /// Creates one display-ready compact book-list row.
  const LibraryBookListItem({
    required this.data,
    required this.onOpen,
    this.onLongPress,
    this.onMore,
    this.actions = const <LibraryBookListAction>[],
    this.onAction,
    this.presentation = LibraryBookListPresentation.recentUpdates,
    this.isPreparing = false,
    super.key,
  });

  final LibraryBookListItemViewData data;
  final VoidCallback onOpen;
  final VoidCallback? onLongPress;
  final VoidCallback? onMore;
  final List<LibraryBookListAction> actions;
  final ValueChanged<LibraryBookListAction>? onAction;
  final LibraryBookListPresentation presentation;
  final bool isPreparing;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final bool showAttentionIndicator = presentation.showAttentionIndicator && data.hasAttentionIndicator;
    final String semanticLabel = _bookListItemLabel(
      title: data.title,
      subtitle: data.subtitle,
      activityLabel: presentation.showActivityLabel ? data.activityLabel : null,
      hasAttentionIndicator: showAttentionIndicator,
    );

    return Semantics(
      container: true,
      liveRegion: isPreparing,
      label: isPreparing ? '正在准备阅读内容' : null,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: AppRadii.surface,
          onTap: onOpen,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.bookListVerticalPadding),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                LibraryBookCover(
                  title: data.title,
                  variant: data.coverVariant,
                  coverBytes: data.coverBytes,
                  coverRequest: data.coverRequest,
                  assetPath: data.coverAssetPath,
                  width: AppSpacing.listCoverWidth,
                  height: AppSpacing.listCoverHeight,
                ),
                const SizedBox(width: AppSpacing.compact + AppSpacing.unit),
                Expanded(
                  child: SizedBox(
                    height: AppSpacing.listCoverHeight,
                    child: Semantics(
                      button: true,
                      label: semanticLabel,
                      child: ExcludeSemantics(
                        child: _BookListDetails(data: data, theme: theme),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.compact),
                _BookListTrailing(
                  data: data,
                  onMore: onMore,
                  actions: actions,
                  onAction: onAction,
                  presentation: presentation,
                  showAttentionIndicator: showAttentionIndicator,
                  theme: theme,
                  tokens: tokens,
                  isPreparing: isPreparing,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A source or availability tag with a theme-derived semantic treatment.
class LibraryMetadataTag extends StatelessWidget {
  /// Creates one compact metadata tag.
  const LibraryMetadataTag({required this.data, super.key});

  final LibraryMetadataTagViewData data;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final (Color background, Color foreground) = switch (data.tone) {
      LibraryMetadataTone.neutral => (tokens.mutedSurface, tokens.mutedText),
      LibraryMetadataTone.accent => (tokens.accentSoft, Color.lerp(tokens.mutedText, tokens.accent, 0.45)!),
      LibraryMetadataTone.success => (tokens.success.withValues(alpha: 0.16), tokens.success),
    };

    return Semantics(
      label: data.label,
      child: ExcludeSemantics(
        child: DecoratedBox(
          decoration: BoxDecoration(color: background, borderRadius: AppRadii.pill),
          child: SizedBox(
            height: AppSpacing.metadataTagHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.unit),
              child: Align(
                widthFactor: 1,
                alignment: Alignment.center,
                child: Text(
                  data.label,
                  style: theme.textTheme.bodySmall?.copyWith(color: foreground, fontWeight: FontWeight.w400, height: 1),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BookListDetails extends StatelessWidget {
  const _BookListDetails({required this.data, required this.theme});

  final LibraryBookListItemViewData data;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Text(
            data.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600, height: 1.18),
          ),
        ),
        if (data.subtitle != null)
          Positioned(
            top: AppSpacing.section,
            left: 0,
            right: 0,
            child: Text(
              data.subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(color: tokens.mutedText, fontWeight: FontWeight.w400, height: 1.2),
            ),
          ),
        if (data.tags.isNotEmpty)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Wrap(
              spacing: AppSpacing.compact,
              runSpacing: AppSpacing.unit,
              children: data.tags.map((LibraryMetadataTagViewData tag) => LibraryMetadataTag(data: tag)).toList(growable: false),
            ),
          ),
      ],
    );
  }
}

class _BookListTrailing extends StatelessWidget {
  const _BookListTrailing({
    required this.data,
    required this.onMore,
    required this.actions,
    required this.onAction,
    required this.presentation,
    required this.showAttentionIndicator,
    required this.theme,
    required this.tokens,
    required this.isPreparing,
  });

  final LibraryBookListItemViewData data;
  final VoidCallback? onMore;
  final List<LibraryBookListAction> actions;
  final ValueChanged<LibraryBookListAction>? onAction;
  final LibraryBookListPresentation presentation;
  final bool showAttentionIndicator;
  final ThemeData theme;
  final AppThemeTokens tokens;
  final bool isPreparing;

  @override
  Widget build(BuildContext context) {
    final bool showMoreAction = presentation.showOverflowAction && (onMore != null || (actions.isNotEmpty && onAction != null));
    final String? activityLabel = presentation.showActivityLabel ? data.activityLabel : null;

    return SizedBox(
      width: AppSpacing.bookListTrailingWidth,
      height: AppSpacing.listCoverHeight,
      child: Stack(
        children: <Widget>[
          if (isPreparing)
            const Align(
              alignment: Alignment.centerRight,
              child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          if (!isPreparing && activityLabel != null)
            Positioned(
              top: AppSpacing.section,
              left: 0,
              right: showMoreAction ? AppSpacing.minimumTouchTarget + AppSpacing.compact : 0,
              child: Text(
                activityLabel,
                textAlign: TextAlign.end,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText, fontWeight: FontWeight.w400, height: 1.2),
              ),
            ),
          if (!isPreparing && showMoreAction)
            Align(
              alignment: Alignment.topRight,
              child: SizedBox(
                width: AppSpacing.minimumTouchTarget,
                height: AppSpacing.minimumTouchTarget,
                child: actions.isNotEmpty && onAction != null
                    ? LibraryAnchoredMenu(
                        tooltip: '书籍更多操作',
                        menuKey: Key('library-book-overflow-menu-${data.id}'),
                        actions: <LibraryAnchoredMenuAction>[
                          for (final action in actions) LibraryAnchoredMenuAction(label: action.label, onSelected: () => onAction!(action)),
                        ],
                        triggerBuilder: (BuildContext context, VoidCallback onPressed) => IconButton(
                          tooltip: '书籍更多操作',
                          onPressed: onPressed,
                          padding: EdgeInsets.zero,
                          iconSize: 16,
                          icon: const Icon(Icons.more_vert_rounded),
                        ),
                      )
                    : IconButton(
                        tooltip: '书籍更多操作',
                        onPressed: onMore,
                        padding: EdgeInsets.zero,
                        iconSize: 16,
                        icon: const Icon(Icons.more_vert_rounded),
                      ),
              ),
            ),
          if (!isPreparing && showAttentionIndicator)
            Positioned(
              top: AppSpacing.section + AppSpacing.unit,
              right: AppSpacing.compact,
              child: Semantics(
                label: '有更新',
                child: ExcludeSemantics(
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: tokens.notification, shape: BoxShape.circle),
                    child: const SizedBox(width: AppSpacing.unreadDotSize, height: AppSpacing.unreadDotSize),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

String _bookListItemLabel({required String title, String? subtitle, String? activityLabel, bool hasAttentionIndicator = false}) {
  final List<String> parts = <String>[title];
  if (subtitle != null && subtitle.isNotEmpty) {
    parts.add(subtitle);
  }
  if (activityLabel != null && activityLabel.isNotEmpty) {
    parts.add(activityLabel);
  }
  if (hasAttentionIndicator) {
    parts.add('有更新');
  }
  return parts.join('，');
}
