/// 首页书籍卡片网格。
///
/// 职责：
/// - 以响应式 Sliver 瀑布流展示等宽、原图比例的封面和真实摘要。
/// - 将点击、长按、加载和书籍操作转发给首页壳。
///
/// 注意：
/// - 不读取书架、封面缓存或持久化；封面继续使用共享请求组件。
/// - 卡片模式必须保留列表模式已有的书籍操作，不建立第二套业务回调。
/// - 图片解码前使用来源方向作为占位比例；解码后高度跟随原图像素比例。
/// - 更新数量使用主题表面色胶囊，避免封面上的高饱和色圆点；超过 99 显示 99+。
///
library;

import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/library/presentation/library_book_list_view_data.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_cover.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_list_action.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_removal_transition.dart';

typedef LibraryBookGridActionSelected = void Function(LibraryBookListItemViewData book, LibraryBookListAction action);

/// A lazy, responsive masonry presentation for the home bookshelf.
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
    this.metadataMode = LibraryHomeCoverMetadataMode.belowCover,
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
  final LibraryHomeCoverMetadataMode metadataMode;

  @override
  Widget build(BuildContext context) {
    return SliverLayoutBuilder(
      builder: (BuildContext context, constraints) {
        const double crossAxisSpacing = AppSpacing.regular;
        final int columnCount = _columnCountForWidth(constraints.crossAxisExtent);
        final double tileWidth = (constraints.crossAxisExtent - crossAxisSpacing * (columnCount - 1)) / columnCount;
        return SliverMasonryGrid.count(
          key: const Key('library-book-card-grid'),
          crossAxisCount: columnCount,
          crossAxisSpacing: crossAxisSpacing,
          mainAxisSpacing: AppSpacing.comfortable,
          childCount: books.length,
          itemBuilder: (BuildContext context, int index) {
            final LibraryBookListItemViewData book = books[index];
            final coverHeight = tileWidth / _coverAspectRatio(book.coverOrientation);
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
                coverWidth: tileWidth,
                coverHeight: coverHeight,
                metadataMode: metadataMode,
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
    required this.coverWidth,
    required this.coverHeight,
    this.metadataMode = LibraryHomeCoverMetadataMode.belowCover,
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
  final double coverWidth;
  final double coverHeight;
  final LibraryHomeCoverMetadataMode metadataMode;

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
                Stack(
                  fit: StackFit.loose,
                  children: <Widget>[
                    DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: AppRadii.bookCover,
                        boxShadow: <BoxShadow>[
                          BoxShadow(color: tokens.shadow.withValues(alpha: 0.12), blurRadius: 10, offset: const Offset(0, 4)),
                        ],
                      ),
                      child: LibraryBookCover(
                        title: data.title,
                        contentKind: data.contentKind,
                        variant: data.coverVariant,
                        coverBytes: data.coverBytes,
                        coverRequest: data.coverRequest,
                        assetPath: data.coverAssetPath,
                        fit: BoxFit.cover,
                        useIntrinsicAspectRatio: true,
                        isBlurred: data.isCoverBlurred,
                        width: coverWidth,
                        height: coverHeight,
                        isRefreshing: isRefreshing,
                      ),
                    ),
                    if (metadataMode == LibraryHomeCoverMetadataMode.insideCover) Positioned.fill(child: _CoverMetadataOverlay(data: data)),
                    if (data.unreadChapterCount > 0 || data.hasAttentionIndicator)
                      Positioned(
                        left: AppSpacing.compact,
                        top: AppSpacing.compact,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: data.unreadChapterCount > 0 ? theme.colorScheme.surfaceContainerHigh : tokens.accent,
                            borderRadius: AppRadii.pill,
                            border: Border.all(color: theme.colorScheme.outlineVariant),
                            boxShadow: <BoxShadow>[
                              BoxShadow(color: tokens.shadow.withValues(alpha: 0.12), blurRadius: 4, offset: const Offset(0, 1)),
                            ],
                          ),
                          child: data.unreadChapterCount > 0
                              ? Container(
                                  constraints: const BoxConstraints(minWidth: 26, minHeight: 22),
                                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.compact),
                                  child: Center(
                                    child: Text(
                                      data.unreadChapterCount > 99 ? '99+' : '${data.unreadChapterCount}',
                                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                        color: theme.colorScheme.onSurface,
                                        fontSize: 11,
                                        height: 1,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                )
                              : const SizedBox.square(dimension: AppSpacing.unreadDotSize + 2),
                        ),
                      ),
                    if (!isPreparing && showMenu)
                      Positioned(
                        right: AppSpacing.unit,
                        top: AppSpacing.unit,
                        child: _GridBookMenu(book: data, actions: actions, onAction: onAction, onMore: onMore),
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
                if (metadataMode == LibraryHomeCoverMetadataMode.belowCover) ...<Widget>[
                  const SizedBox(height: AppSpacing.compact),
                  _BookReadingLabel(data: data),
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

/// 内容类型和真实阅读进度共享一行，不占用封面角上的更新与菜单位置。
class _BookReadingLabel extends StatelessWidget {
  const _BookReadingLabel({required this.data, this.onCover = false});
  final LibraryBookListItemViewData data;
  final bool onCover;
  @override
  Widget build(BuildContext context) {
    final kind = switch (data.contentKind) {
      ContentKind.novel => '小说',
      ContentKind.manga => '漫画',
      ContentKind.audio => '音频',
      ContentKind.video => '视频',
    };
    final progress = data.readingProgress;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.unit),
      child: Text(
        progress == null ? kind : '$kind · ${(progress.clamp(0, 1) * 100).round()}%',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: onCover ? Colors.white : AppThemeTokens.of(context).accent),
      ),
    );
  }
}

class _CoverMetadataOverlay extends StatelessWidget {
  const _CoverMetadataOverlay({required this.data});

  final LibraryBookListItemViewData data;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle titleStyle = (theme.textTheme.titleMedium ?? const TextStyle()).copyWith(
      color: Colors.white,
      fontSize: AppTypography.body,
      fontWeight: FontWeight.w700,
      height: 1.15,
      shadows: const <Shadow>[Shadow(color: Colors.black54, blurRadius: 4)],
    );
    final TextStyle subtitleStyle = (theme.textTheme.bodySmall ?? const TextStyle()).copyWith(
      color: Colors.white.withValues(alpha: 0.88),
      fontSize: AppTypography.caption,
      height: 1.2,
      shadows: const <Shadow>[Shadow(color: Colors.black54, blurRadius: 3)],
    );
    return IgnorePointer(
      child: ClipRRect(
        borderRadius: AppRadii.bookCover,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[Colors.transparent, Color(0xC9000000)],
              stops: <double>[0.52, 1],
            ),
          ),
          child: Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.compact, AppSpacing.page, AppSpacing.compact, AppSpacing.compact),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _BookReadingLabel(data: data, onCover: true),
                  Text(
                    data.title,
                    key: Key('library-grid-book-overlay-title-${data.id}'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: titleStyle,
                  ),
                  if (data.subtitle case final subtitle?)
                    Text(
                      subtitle,
                      key: Key('library-grid-book-overlay-subtitle-${data.id}'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: subtitleStyle,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

double _coverAspectRatio(CoverOrientation orientation) => switch (orientation) {
  CoverOrientation.portrait => 0.72,
  CoverOrientation.square => 1,
  CoverOrientation.landscape => 16 / 9,
};

int _columnCountForWidth(double width) => switch (width) {
  < 600 => 2,
  < 840 => 3,
  < 1120 => 4,
  < 1440 => 5,
  < 1760 => 6,
  _ => 7,
};

class _GridBookMenu extends StatefulWidget {
  const _GridBookMenu({required this.book, required this.actions, required this.onAction, required this.onMore});

  final LibraryBookListItemViewData book;
  final List<LibraryBookListAction> actions;
  final ValueChanged<LibraryBookListAction>? onAction;
  final VoidCallback? onMore;

  @override
  State<_GridBookMenu> createState() => _GridBookMenuState();
}

class _GridBookMenuState extends State<_GridBookMenu> {
  bool _isHovered = false;
  bool _isFocused = false;
  bool _isMenuOpen = false;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final bool isEmphasized = _isHovered || _isFocused || _isMenuOpen;
    final Widget trigger = AnimatedContainer(
      key: Key('library-grid-book-menu-surface-${widget.book.id}'),
      duration: AppMotion.effectiveDuration(context, AppMotion.micro),
      curve: AppMotion.navigationCurve,
      decoration: BoxDecoration(
        color: tokens.surface.withValues(alpha: isEmphasized ? 0.9 : 0.56),
        shape: BoxShape.circle,
        boxShadow: isEmphasized ? <BoxShadow>[BoxShadow(color: tokens.shadow.withValues(alpha: 0.1), blurRadius: 6)] : const <BoxShadow>[],
      ),
      child: SizedBox.square(
        dimension: 32,
        child: Center(
          child: AnimatedOpacity(
            duration: AppMotion.effectiveDuration(context, AppMotion.micro),
            curve: AppMotion.navigationCurve,
            opacity: isEmphasized ? 1 : 0.68,
            child: const Icon(Icons.more_vert_rounded, size: 17),
          ),
        ),
      ),
    );

    final Widget button;
    if (widget.actions.isNotEmpty && widget.onAction != null) {
      button = PopupMenuButton<LibraryBookListAction>(
        key: Key('library-grid-book-overflow-menu-${widget.book.id}'),
        tooltip: '书籍更多操作',
        position: PopupMenuPosition.under,
        shape: RoundedRectangleBorder(borderRadius: AppRadii.surface),
        elevation: 4,
        onOpened: () => setState(() => _isMenuOpen = true),
        onCanceled: () => setState(() => _isMenuOpen = false),
        onSelected: (LibraryBookListAction action) {
          setState(() => _isMenuOpen = false);
          widget.onAction!(action);
        },
        itemBuilder: (BuildContext context) => <PopupMenuEntry<LibraryBookListAction>>[
          for (final LibraryBookListAction action in widget.actions)
            PopupMenuItem<LibraryBookListAction>(
              key: Key('library-grid-book-action-${widget.book.id}-${action.id}'),
              value: action,
              child: Text(action.labelFor(widget.book)),
            ),
        ],
        child: trigger,
      );
    } else {
      button = IconButton(
        tooltip: '书籍更多操作',
        onPressed: widget.onMore,
        padding: EdgeInsets.zero,
        iconSize: 17,
        style: IconButton.styleFrom(minimumSize: const Size.square(32), fixedSize: const Size.square(32)),
        icon: trigger,
      );
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Focus(onFocusChange: (bool value) => setState(() => _isFocused = value), child: button),
    );
  }
}
