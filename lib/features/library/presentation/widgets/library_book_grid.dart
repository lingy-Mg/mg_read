/// 首页书籍卡片网格。
///
/// 职责：
/// - 以响应式 Sliver 网格展示首页书籍封面和真实摘要。
/// - 将点击、长按、加载和书籍操作转发给首页壳。
///
/// 注意：
/// - 不读取书架、封面缓存或持久化；封面继续使用共享请求组件。
/// - 卡片模式必须保留列表模式已有的书籍操作，不建立第二套业务回调。
///
/// TODO:
/// - 无。
library;

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/presentation/library_book_list_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_cover.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_list_action.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_removal_transition.dart';

typedef LibraryBookGridActionSelected = void Function(LibraryBookListItemViewData book, LibraryBookListAction action);

/// A lazy, responsive card presentation for the home bookshelf.
class LibraryBookSliverGrid extends StatelessWidget {
  LibraryBookSliverGrid({
    required Iterable<LibraryBookListItemViewData> books,
    required this.onOpenBook,
    this.onBookLongPress,
    this.onBookMore,
    this.actions = const <LibraryBookListAction>[],
    this.onBookAction,
    this.preparingBookId,
    this.removingBookIds = const <String>{},
    this.refreshingBookIds = const <String>{},
    super.key,
  }) : books = List<LibraryBookListItemViewData>.unmodifiable(books);

  final List<LibraryBookListItemViewData> books;
  final ValueChanged<LibraryBookListItemViewData> onOpenBook;
  final ValueChanged<LibraryBookListItemViewData>? onBookLongPress;
  final ValueChanged<LibraryBookListItemViewData>? onBookMore;
  final List<LibraryBookListAction> actions;
  final LibraryBookGridActionSelected? onBookAction;
  final String? preparingBookId;
  final Set<String> removingBookIds;
  final Set<String> refreshingBookIds;

  @override
  Widget build(BuildContext context) {
    return SliverLayoutBuilder(
      builder: (BuildContext context, constraints) {
        const double crossAxisSpacing = AppSpacing.regular;
        final int columnCount = (constraints.crossAxisExtent / 112).floor().clamp(3, 7);
        final double tileWidth = (constraints.crossAxisExtent - crossAxisSpacing * (columnCount - 1)) / columnCount;
        final double coverHeight = tileWidth / 0.72;
        final double textScale = MediaQuery.textScalerOf(context).scale(1).clamp(1, 1.6);
        final double detailsHeight = 58 * textScale;
        return SliverGrid.builder(
          key: const Key('library-book-card-grid'),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columnCount,
            crossAxisSpacing: crossAxisSpacing,
            mainAxisSpacing: AppSpacing.comfortable,
            mainAxisExtent: coverHeight + detailsHeight,
          ),
          itemCount: books.length,
          itemBuilder: (BuildContext context, int index) {
            final LibraryBookListItemViewData book = books[index];
            return LibraryBookRemovalTransition(
              key: ValueKey<String>('library-grid-removal-${book.id}'),
              isRemoving: removingBookIds.contains(book.id),
              child: LibraryBookGridItem(
                data: book,
                onOpen: () => onOpenBook(book),
                onLongPress: onBookLongPress == null ? null : () => onBookLongPress!(book),
                onMore: onBookMore == null ? null : () => onBookMore!(book),
                actions: actions,
                onAction: onBookAction == null ? null : (LibraryBookListAction action) => onBookAction!(book, action),
                isPreparing: preparingBookId == book.id,
                isRefreshing: refreshingBookIds.contains(book.id),
              ),
            );
          },
        );
      },
    );
  }
}

/// One interactive book card used by [LibraryBookSliverGrid].
class LibraryBookGridItem extends StatelessWidget {
  const LibraryBookGridItem({
    required this.data,
    required this.onOpen,
    this.onLongPress,
    this.onMore,
    this.actions = const <LibraryBookListAction>[],
    this.onAction,
    this.isPreparing = false,
    this.isRefreshing = false,
    super.key,
  });

  final LibraryBookListItemViewData data;
  final VoidCallback onOpen;
  final VoidCallback? onLongPress;
  final VoidCallback? onMore;
  final List<LibraryBookListAction> actions;
  final ValueChanged<LibraryBookListAction>? onAction;
  final bool isPreparing;
  final bool isRefreshing;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final bool showMenu = onMore != null || (actions.isNotEmpty && onAction != null);
    return Semantics(
      container: true,
      button: true,
      liveRegion: isPreparing,
      label: isPreparing ? '${data.title}，正在准备阅读内容' : _semanticLabel,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey<String>('library-book-card-${data.id}'),
          onTap: isPreparing ? null : onOpen,
          onLongPress: isPreparing ? null : onLongPress,
          borderRadius: AppRadii.surface,
          child: ExcludeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      LayoutBuilder(
                        builder: (BuildContext context, BoxConstraints constraints) {
                          return DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: AppRadii.bookCover,
                              boxShadow: <BoxShadow>[
                                BoxShadow(color: tokens.shadow.withValues(alpha: 0.12), blurRadius: 10, offset: const Offset(0, 4)),
                              ],
                            ),
                            child: LibraryBookCover(
                              title: data.title,
                              variant: data.coverVariant,
                              coverBytes: data.coverBytes,
                              coverRequest: data.coverRequest,
                              assetPath: data.coverAssetPath,
                              width: constraints.maxWidth,
                              height: constraints.maxHeight,
                              isRefreshing: isRefreshing,
                            ),
                          );
                        },
                      ),
                      if (data.hasAttentionIndicator)
                        Positioned(
                          left: AppSpacing.compact,
                          top: AppSpacing.compact,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: tokens.notification,
                              shape: BoxShape.circle,
                              border: Border.all(color: tokens.surface, width: 1.5),
                            ),
                            child: const SizedBox.square(dimension: AppSpacing.unreadDotSize + 2),
                          ),
                        ),
                      if (!isPreparing && showMenu)
                        Positioned(
                          right: AppSpacing.unit,
                          top: AppSpacing.unit,
                          child: _GridBookMenu(bookId: data.id, actions: actions, onAction: onAction, onMore: onMore),
                        ),
                      if (isPreparing)
                        Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.22), borderRadius: AppRadii.bookCover),
                            child: const Center(
                              child: SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.compact),
                Text(
                  data.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(fontSize: AppTypography.body, fontWeight: FontWeight.w600, height: 1.22),
                ),
                if (data.subtitle case final subtitle?) ...<Widget>[
                  const SizedBox(height: AppSpacing.unit),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText, fontSize: AppTypography.caption, height: 1.2),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  String get _semanticLabel {
    final String? subtitle = data.subtitle;
    return subtitle == null || subtitle.isEmpty ? data.title : '${data.title}，$subtitle';
  }
}

class _GridBookMenu extends StatelessWidget {
  const _GridBookMenu({required this.bookId, required this.actions, required this.onAction, required this.onMore});

  final String bookId;
  final List<LibraryBookListAction> actions;
  final ValueChanged<LibraryBookListAction>? onAction;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    Widget triggerIcon() => DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surface.withValues(alpha: 0.9),
        shape: BoxShape.circle,
        boxShadow: <BoxShadow>[BoxShadow(color: tokens.shadow.withValues(alpha: 0.1), blurRadius: 6)],
      ),
      child: const SizedBox.square(dimension: 32, child: Center(child: Icon(Icons.more_vert_rounded, size: 17))),
    );

    if (actions.isNotEmpty && onAction != null) {
      return PopupMenuButton<LibraryBookListAction>(
        key: Key('library-grid-book-overflow-menu-$bookId'),
        tooltip: '书籍更多操作',
        position: PopupMenuPosition.under,
        shape: RoundedRectangleBorder(borderRadius: AppRadii.surface),
        elevation: 4,
        onSelected: onAction,
        itemBuilder: (BuildContext context) => <PopupMenuEntry<LibraryBookListAction>>[
          for (final LibraryBookListAction action in actions)
            PopupMenuItem<LibraryBookListAction>(
              key: Key('library-grid-book-action-$bookId-${action.id}'),
              value: action,
              child: Text(action.label),
            ),
        ],
        child: triggerIcon(),
      );
    }
    return IconButton(
      tooltip: '书籍更多操作',
      onPressed: onMore,
      padding: EdgeInsets.zero,
      iconSize: 17,
      style: IconButton.styleFrom(
        minimumSize: const Size.square(32),
        fixedSize: const Size.square(32),
        backgroundColor: tokens.surface.withValues(alpha: 0.9),
        shadowColor: tokens.shadow.withValues(alpha: 0.1),
        elevation: 2,
      ),
      icon: const Icon(Icons.more_vert_rounded),
    );
  }
}
