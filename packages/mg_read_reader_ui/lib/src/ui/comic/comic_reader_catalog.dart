/// 漫画目录面板。
///
/// 职责：
/// - 补齐分页目录并将当前章节定位到可视区域中部。
/// - 展示章节序号、图片数、阅读状态、缓存状态和当前章节层级。
/// - 保持大目录的渐进加载、显式重试与会话世代隔离。
///
/// 注意：目录只消费会话已有的公开元数据，不自行访问网络或持久层。
part of 'comic_reader_view.dart';

// ignore_for_file: invalid_use_of_protected_member

const double _comicCatalogItemExtent = 64;
const double _comicCatalogTopPadding = 8;
const double _comicCatalogScrollbarThickness = 16;

extension _ComicReaderCatalog on _ComicReaderViewState {
  void _showCatalog() {
    final int session = _sessionGeneration;
    final String bookId = widget.bookId;
    final ComicReaderDataSource source = widget.dataSource;
    final ComicReaderStateStore store = widget.stateStore;
    bool isCurrent() => _isSession(session, bookId, source, store);
    final int sheetGeneration = _beginSheet();
    final ScrollController catalogScrollController = ScrollController();
    final ValueNotifier<int> catalogRevision = ValueNotifier<int>(0);
    _activeCatalogRevision = catalogRevision;
    var catalogCompletionStarted = false;
    _setControlsVisible(false);
    final Future<void> sheet = showModalBottomSheet<void>(
      context: context,
      sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : null,
      isScrollControlled: true,
      isDismissible: true,
      enableDrag: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: .68),
      builder: (BuildContext sheetContext) {
        _captureSheetContext(sheetContext, sheetGeneration);
        return StatefulBuilder(
          builder: (BuildContext context, void Function(VoidCallback) _) {
            if (!catalogCompletionStarted) {
              catalogCompletionStarted = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                unawaited(
                  _completeCatalogForSheet(
                    sheetContext: sheetContext,
                    sheetGeneration: sheetGeneration,
                    isCurrent: isCurrent,
                    catalogRevision: catalogRevision,
                    catalogScrollController: catalogScrollController,
                  ),
                );
              });
            }
            final ReaderPalette palette = ReaderPalette.fromPreset(
              ReaderThemePreset.deepNight,
            );
            final MediaQueryData mediaQuery = MediaQuery.of(context);
            final double sheetHeight = (mediaQuery.size.height * .76)
                .clamp(0, 640)
                .toDouble();
            return MediaQuery(
              data: mediaQuery.copyWith(
                textScaler: mediaQuery.textScaler.clamp(maxScaleFactor: 1.3),
              ),
              child: SizedBox(
                width: double.infinity,
                height: sheetHeight,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 680),
                    child: SizedBox(
                      height: sheetHeight,
                      child: ClipRRect(
                        key: const ValueKey<String>(
                          'comic-reader-catalog-sheet',
                        ),
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(22),
                        ),
                        child: Material(
                          color: palette.panel,
                          child: _darkSheet(
                            SafeArea(
                              top: false,
                              child: ValueListenableBuilder<int>(
                                valueListenable: catalogRevision,
                                builder:
                                    (
                                      BuildContext context,
                                      int revision,
                                      Widget? child,
                                    ) {
                                      return Column(
                                        children: <Widget>[
                                          const SizedBox(height: 9),
                                          Container(
                                            width: 36,
                                            height: 4,
                                            decoration: BoxDecoration(
                                              color: palette.divider,
                                              borderRadius:
                                                  BorderRadius.circular(2),
                                            ),
                                          ),
                                          _comicCatalogHeader(palette),
                                          Divider(
                                            height: 1,
                                            color: palette.divider,
                                          ),
                                          Expanded(
                                            child: _buildComicCatalogList(
                                              sheetContext: sheetContext,
                                              palette: palette,
                                              isCurrent: isCurrent,
                                              catalogRevision: catalogRevision,
                                              sheetGeneration: sheetGeneration,
                                              catalogScrollController:
                                                  catalogScrollController,
                                            ),
                                          ),
                                        ],
                                      );
                                    },
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
    unawaited(
      sheet.whenComplete(() {
        _finishSheet(sheetGeneration);
        catalogScrollController.dispose();
        if (identical(_activeCatalogRevision, catalogRevision)) {
          _activeCatalogRevision = null;
        }
        catalogRevision.dispose();
      }),
    );
  }

  Widget _comicCatalogHeader(ReaderPalette palette) {
    final int total = _catalogTotal > 0 ? _catalogTotal : _catalog.length;
    final String? bookTitle = _book?.title.trim();
    return SizedBox(
      height: 70,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
        child: Row(
          children: <Widget>[
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: palette.accent.withValues(alpha: .14),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.view_list_rounded,
                size: 21,
                color: palette.accent,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    ComicReaderStrings.catalog,
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  if (bookTitle != null && bookTitle.isNotEmpty)
                    Text(
                      bookTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.secondaryText,
                        fontSize: 11.5,
                      ),
                    ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: palette.background.withValues(alpha: .72),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                ComicReaderStrings.chapterCount(total),
                style: TextStyle(
                  color: palette.secondaryText,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (widget.bookRefreshCapability != null)
              IconButton(
                key: const ValueKey<String>('comic-reader-refresh-book'),
                tooltip: ComicReaderStrings.refreshBook,
                onPressed: _bookRefreshLoading
                    ? null
                    : () => unawaited(_refreshBookFromHost()),
                icon: _bookRefreshLoading
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync_rounded),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildComicCatalogList({
    required BuildContext sheetContext,
    required ReaderPalette palette,
    required bool Function() isCurrent,
    required ValueNotifier<int> catalogRevision,
    required int sheetGeneration,
    required ScrollController catalogScrollController,
  }) {
    if (_catalog.isEmpty && !_catalogHasMore && !_catalogLoading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.menu_book_outlined,
              size: 38,
              color: palette.secondaryText,
            ),
            const SizedBox(height: 10),
            Text(
              ComicReaderStrings.noChapters,
              style: TextStyle(color: palette.secondaryText),
            ),
          ],
        ),
      );
    }
    return RawScrollbar(
      key: const ValueKey<String>('comic-reader-catalog-scrollbar'),
      controller: catalogScrollController,
      thumbVisibility: true,
      interactive: true,
      thickness: _comicCatalogScrollbarThickness,
      radius: const Radius.circular(_comicCatalogScrollbarThickness / 2),
      minThumbLength: 52,
      minOverscrollLength: 52,
      mainAxisMargin: 8,
      crossAxisMargin: 2,
      thumbColor: palette.secondaryText.withValues(alpha: .72),
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(
          sheetContext,
        ).copyWith(scrollbars: false),
        child: ListView.builder(
          key: ValueKey<String>(
            'comic-reader-catalog-scroll-${widget.bookId}-${_catalog.length}',
          ),
          controller: catalogScrollController,
          padding: const EdgeInsets.fromLTRB(12, 8, 32, 20),
          itemExtent: _comicCatalogItemExtent,
          itemCount:
              _catalog.length + (_catalogHasMore || _catalogLoading ? 1 : 0),
          itemBuilder: (BuildContext context, int index) {
            if (index == _catalog.length) {
              return Center(
                child: _catalogLoading
                    ? SizedBox(
                        key: const ValueKey<String>(
                          'comic-reader-catalog-loading',
                        ),
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: palette.accent,
                        ),
                      )
                    : TextButton.icon(
                        key: const ValueKey<String>(
                          'comic-reader-catalog-load-more',
                        ),
                        onPressed: () async {
                          if (!isCurrent()) {
                            if (sheetContext.mounted) {
                              Navigator.of(sheetContext).pop();
                            }
                            return;
                          }
                          await _completeCatalogForSheet(
                            sheetContext: sheetContext,
                            sheetGeneration: sheetGeneration,
                            isCurrent: isCurrent,
                            catalogRevision: catalogRevision,
                            catalogScrollController: catalogScrollController,
                          );
                        },
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text(ComicReaderStrings.loadMore),
                      ),
              );
            }
            final ComicChapterInfo chapter = _catalog[index];
            final bool isCurrentChapter = chapter.id == _currentChapter?.id;
            final Color textColor = isCurrentChapter
                ? palette.accent
                : chapter.hasBeenRead
                ? palette.secondaryText
                : palette.text;
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: ListTile(
                  key: ValueKey<String>(
                    'comic-reader-catalog-chapter-${chapter.id}',
                  ),
                  dense: true,
                  visualDensity: const VisualDensity(vertical: -1),
                  minVerticalPadding: 0,
                  titleAlignment: ListTileTitleAlignment.center,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 2,
                  ),
                  tileColor: isCurrentChapter
                      ? palette.accent.withValues(alpha: .14)
                      : null,
                  hoverColor: palette.accent.withValues(alpha: .08),
                  selected: isCurrentChapter,
                  selectedColor: palette.accent,
                  selectedTileColor: palette.accent.withValues(alpha: .14),
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(Radius.circular(14)),
                  ),
                  leading: SizedBox(
                    width: 38,
                    child: Text(
                      '${chapter.index + 1}',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: textColor,
                        fontSize: isCurrentChapter ? 12.5 : 12,
                        fontWeight: isCurrentChapter || !chapter.hasBeenRead
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                  title: Text(
                    chapter.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: textColor,
                      fontSize: isCurrentChapter ? 14.5 : 14,
                      fontWeight: isCurrentChapter
                          ? FontWeight.w700
                          : chapter.hasBeenRead
                          ? FontWeight.w400
                          : FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    _chapterStatus(chapter),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: chapter.hasBeenRead
                          ? palette.secondaryText.withValues(alpha: .82)
                          : palette.secondaryText,
                      fontSize: 11.5,
                    ),
                  ),
                  trailing: SizedBox(
                    width: 36,
                    child: isCurrentChapter
                        ? DecoratedBox(
                            decoration: BoxDecoration(
                              color: palette.accent.withValues(alpha: .16),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Center(
                              child: Icon(
                                Icons.play_arrow_rounded,
                                size: 17,
                                color: palette.accent,
                              ),
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                  onTap: () {
                    if (!isCurrent()) {
                      Navigator.of(context).pop();
                      return;
                    }
                    Navigator.of(context).pop();
                    unawaited(_openChapterInfo(chapter, replaceWindow: true));
                  },
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _completeCatalogForSheet({
    required BuildContext sheetContext,
    required int sheetGeneration,
    required bool Function() isCurrent,
    required ValueNotifier<int> catalogRevision,
    required ScrollController catalogScrollController,
  }) async {
    while (isCurrent() &&
        sheetGeneration == _sheetGeneration &&
        sheetContext.mounted &&
        _catalogHasMore) {
      final bool loaded = await _loadNextCatalogPage();
      if (!isCurrent() ||
          sheetGeneration != _sheetGeneration ||
          !sheetContext.mounted) {
        return;
      }
      catalogRevision.value++;
      _scheduleComicCatalogCenter(
        sheetContext: sheetContext,
        sheetGeneration: sheetGeneration,
        isCurrent: isCurrent,
        catalogScrollController: catalogScrollController,
      );
      if (!loaded) return;
      await Future<void>.delayed(Duration.zero);
    }
    if (!isCurrent() ||
        sheetGeneration != _sheetGeneration ||
        !sheetContext.mounted) {
      return;
    }
    _scheduleComicCatalogCenter(
      sheetContext: sheetContext,
      sheetGeneration: sheetGeneration,
      isCurrent: isCurrent,
      catalogScrollController: catalogScrollController,
    );
  }

  void _scheduleComicCatalogCenter({
    required BuildContext sheetContext,
    required int sheetGeneration,
    required bool Function() isCurrent,
    required ScrollController catalogScrollController,
    int attempt = 0,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!sheetContext.mounted ||
          !isCurrent() ||
          sheetGeneration != _sheetGeneration) {
        return;
      }
      final String? currentChapterId = _currentChapter?.id;
      final int chapterIndex = _catalog.indexWhere(
        (ComicChapterInfo chapter) => chapter.id == currentChapterId,
      );
      if (chapterIndex < 0 || !catalogScrollController.hasClients) return;
      final ScrollPosition position = catalogScrollController.position;
      final double minimumVisibleOffset =
          (_comicCatalogTopPadding +
                  (chapterIndex + 1) * _comicCatalogItemExtent -
                  position.viewportDimension)
              .clamp(0, double.infinity);
      if (position.maxScrollExtent + 1 < minimumVisibleOffset) {
        if (attempt >= 4) return;
        _scheduleComicCatalogCenter(
          sheetContext: sheetContext,
          sheetGeneration: sheetGeneration,
          isCurrent: isCurrent,
          catalogScrollController: catalogScrollController,
          attempt: attempt + 1,
        );
        WidgetsBinding.instance.scheduleFrame();
        return;
      }
      final double centeredOffset =
          _comicCatalogTopPadding +
          chapterIndex * _comicCatalogItemExtent -
          (position.viewportDimension - _comicCatalogItemExtent) / 2;
      catalogScrollController.jumpTo(
        centeredOffset.clamp(0, position.maxScrollExtent),
      );
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  String _chapterStatus(ComicChapterInfo chapter) {
    final String count = chapter.imageCount == null
        ? ''
        : ComicReaderStrings.imageCount(chapter.imageCount!);
    final String read = chapter.hasBeenRead
        ? ComicReaderStrings.read
        : ComicReaderStrings.unread;
    final int? cachedImageCount = chapter.cachedImageCount;
    final int totalImageCount = chapter.imageCount ?? 0;
    final String progress =
        cachedImageCount == null || chapter.imageCount == null
        ? ''
        : '$cachedImageCount/$totalImageCount';
    final String availability = switch (chapter.availability) {
      ReaderChapterAvailability.downloaded =>
        progress.isEmpty
            ? ComicReaderStrings.cached
            : '${ComicReaderStrings.cached} $progress',
      ReaderChapterAvailability.downloading =>
        progress.isEmpty
            ? ComicReaderStrings.cachingStatus
            : '${ComicReaderStrings.cachingStatus} $progress',
      ReaderChapterAvailability.notDownloaded => ComicReaderStrings.notCached,
      ReaderChapterAvailability.failed =>
        progress.isEmpty
            ? ComicReaderStrings.cacheFailedStatus
            : '${ComicReaderStrings.cacheFailedStatus} $progress',
      ReaderChapterAvailability.unknown =>
        chapter.manifestCached ? ComicReaderStrings.manifestCached : '',
    };
    final String failures = chapter.failedImageCount > 0
        ? ComicReaderStrings.failedImageCount(chapter.failedImageCount)
        : '';
    return <String>[
      count,
      read,
      availability,
      failures,
    ].where((value) => value.isNotEmpty).join(' · ');
  }
}
