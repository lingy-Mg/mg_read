/// 小说阅读器目录面板的列表和当前章节定位。
///
/// 职责：渐进显示目录、章节状态，并将当前章节移入可视区域。
/// 注意：目录与滚动状态由 _TextReaderViewState 持有，异步回调校验会话。
part of 'text_reader_view.dart';

// ignore_for_file: invalid_use_of_protected_member

const double _catalogChapterItemExtent = 54;
const double _catalogListTopPadding = 8;
const double _catalogScrollbarThickness = 18;
const double _catalogScrollbarMinThumbLength = 52;
const double _catalogListHorizontalPadding = 8;
const double _catalogScrollbarSafetyPadding = 20;
const double _catalogTileHorizontalPadding = 6;

extension _TextReaderLibraryCatalog on _TextReaderViewState {
  Widget _buildCatalogList(
    BuildContext sheetContext,
    int routeSession,
    String routeBookId,
    TextReaderStateStore routeStore,
  ) => Column(
    children: <Widget>[
      _buildBookRefreshAction(
        routeSession,
        routeBookId,
        title: ReaderStrings.catalog,
      ),
      Expanded(
        child: _buildCatalogListBody(
          sheetContext,
          routeSession,
          routeBookId,
          routeStore,
        ),
      ),
    ],
  );

  Widget _buildCatalogListBody(
    BuildContext sheetContext,
    int routeSession,
    String routeBookId,
    TextReaderStateStore routeStore,
  ) {
    bool catalogCompletionStarted = false;
    Widget buildList() => ValueListenableBuilder<int>(
      valueListenable: _catalogRevision,
      builder: (BuildContext context, int revision, Widget? child) {
        final String? currentChapterId = _content?.chapterId;
        final List<ReaderChapterInfo> visibleCatalog = _catalog
            .where((chapter) => !chapter.isContinuation)
            .toList(growable: false);
        final String? currentLogicalChapterId = _logicalCatalogChapterId(
          currentChapterId,
        );
        if (!catalogCompletionStarted) {
          catalogCompletionStarted = true;
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            if (!_isRouteSessionCurrent(
              routeSession,
              routeBookId,
              store: routeStore,
            )) {
              return;
            }
            final Future<void> catalogCompletion = _loadCompleteCatalog(
              notify: false,
            );
            await catalogCompletion;
            if (!context.mounted ||
                !_isRouteSessionCurrent(
                  routeSession,
                  routeBookId,
                  store: routeStore,
                )) {
              return;
            }
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _centerCurrentCatalogChapterInView(
                sheetContext: sheetContext,
                routeSession: routeSession,
                routeBookId: routeBookId,
                routeStore: routeStore,
              );
            });
          });
        }
        if (_catalog.isEmpty && !_catalogHasMore && !_catalogLoading) {
          return _ReaderEmptyState(
            icon: Icons.menu_book_outlined,
            message: ReaderStrings.noChapters,
            color: _palette.secondaryText,
          );
        }
        if (currentChapterId != null &&
            _centeredCatalogChapterId != currentChapterId) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _centerCurrentCatalogChapterInView(
              sheetContext: sheetContext,
              routeSession: routeSession,
              routeBookId: routeBookId,
              routeStore: routeStore,
            );
          });
        }
        return RawScrollbar(
          key: const ValueKey<String>('reader-catalog-scrollbar'),
          controller: _catalogScrollController,
          thumbVisibility: true,
          interactive: true,
          thickness: _catalogScrollbarThickness,
          radius: const Radius.circular(_catalogScrollbarThickness / 2),
          minThumbLength: _catalogScrollbarMinThumbLength,
          minOverscrollLength: _catalogScrollbarMinThumbLength,
          mainAxisMargin: 8,
          crossAxisMargin: 2,
          thumbColor: _palette.secondaryText.withValues(alpha: .82),
          // Reserve only enough gutter to keep trailing metadata off the thumb.
          child: ScrollConfiguration(
            // Rebuild stale sliver geometry without changing book PageStorage.
            key: ValueKey<(int, bool)>((_catalog.length, _catalogHasMore)),
            behavior: ScrollConfiguration.of(
              context,
            ).copyWith(scrollbars: false),
            child: ListView.builder(
              key: PageStorageKey<String>('reader-catalog-scroll-$routeBookId'),
              controller: _catalogScrollController,
              padding: const EdgeInsets.fromLTRB(
                _catalogListHorizontalPadding,
                _catalogListTopPadding,
                _catalogScrollbarSafetyPadding,
                20,
              ),
              itemExtent: _catalogChapterItemExtent,
              itemCount: visibleCatalog.length + (_catalogHasMore ? 1 : 0),
              itemBuilder: (BuildContext context, int index) {
                if (index == visibleCatalog.length) {
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: OutlinedButton(
                      onPressed: _catalogLoading
                          ? null
                          : () async {
                              if (!_isRouteSessionCurrent(
                                routeSession,
                                routeBookId,
                                store: routeStore,
                              )) {
                                return;
                              }
                              await _loadCompleteCatalog(notify: false);
                              if (!sheetContext.mounted ||
                                  !_isRouteSessionCurrent(
                                    routeSession,
                                    routeBookId,
                                    store: routeStore,
                                  )) {
                                return;
                              }
                            },
                      child: Text(
                        _catalogLoading
                            ? ReaderStrings.loading
                            : ReaderStrings.loadMoreChapters,
                      ),
                    ),
                  );
                }
                final ReaderChapterInfo chapter = visibleCatalog[index];
                final bool isCurrentChapter =
                    chapter.id == currentLogicalChapterId;
                final ReaderChapterState? refreshedState =
                    _chapterAccessCoordinator?.snapshot.states[chapter.id];
                final ReaderChapterAvailability availability =
                    refreshedState == null
                    ? chapter.availability
                    : refreshedState.availability;
                final int? wordCount = refreshedState == null
                    ? chapter.wordCount
                    : refreshedState.wordCount;
                final bool hasBeenRead = refreshedState == null
                    ? chapter.hasBeenRead
                    : refreshedState.hasBeenRead;
                final bool stateLoading =
                    _chapterAccessCoordinator?.snapshot.loading == true;
                final Color? chapterBackground = isCurrentChapter
                    ? _palette.accent.withValues(alpha: .14)
                    : null;
                final Color chapterTextColor = isCurrentChapter
                    ? _palette.accent
                    : hasBeenRead
                    ? _palette.secondaryText
                    : _palette.text;
                return Material(
                  type: MaterialType.transparency,
                  borderRadius: const BorderRadius.all(Radius.circular(14)),
                  clipBehavior: Clip.antiAlias,
                  child: ListTile(
                    key: ValueKey<String>(
                      'reader-catalog-chapter-${chapter.id}',
                    ),
                    dense: true,
                    visualDensity: const VisualDensity(vertical: -2),
                    minTileHeight: _catalogChapterItemExtent,
                    minVerticalPadding: 0,
                    titleAlignment: ListTileTitleAlignment.center,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: _catalogTileHorizontalPadding,
                      vertical: 2,
                    ),
                    tileColor: chapterBackground,
                    hoverColor: _palette.accent.withValues(alpha: .08),
                    selected: isCurrentChapter,
                    selectedColor: _palette.accent,
                    selectedTileColor: _palette.accent.withValues(alpha: .15),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(14)),
                    ),
                    leading: SizedBox(
                      width: 30,
                      child: Text(
                        '${index + 1}',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: chapterTextColor,
                          fontSize: isCurrentChapter ? 12.5 : 12,
                          fontWeight: isCurrentChapter || !hasBeenRead
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                    title: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            chapter.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: isCurrentChapter ? 14.5 : 14,
                              fontWeight: isCurrentChapter
                                  ? FontWeight.w700
                                  : hasBeenRead
                                  ? FontWeight.w400
                                  : FontWeight.w600,
                              color: chapterTextColor,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ReaderChapterStateBadge(
                          availability: availability,
                          wordCount: wordCount,
                          hasBeenRead: hasBeenRead,
                          loading: stateLoading && refreshedState == null,
                          palette: _palette,
                          onRetry:
                              availability == ReaderChapterAvailability.failed
                              ? () => unawaited(
                                  _refreshLoadedChapterStates(
                                    chapterId: chapter.id,
                                    force: true,
                                  ),
                                )
                              : null,
                        ),
                      ],
                    ),
                    // Keep word counts aligned independently of title length.
                    trailing: SizedBox(
                      width: 54,
                      child: Text(
                        wordCount != null && wordCount >= 0
                            ? ReaderChapterStateStrings.wordCount(wordCount)
                            : '—',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: isCurrentChapter
                              ? chapterTextColor
                              : _palette.secondaryText,
                          fontSize: 11.5,
                          fontWeight: isCurrentChapter
                              ? FontWeight.w600
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                    onTap: () {
                      if (!_isRouteSessionCurrent(
                        routeSession,
                        routeBookId,
                        store: routeStore,
                      )) {
                        return;
                      }
                      Navigator.of(sheetContext).pop();
                      unawaited(
                        _openChapter(
                          chapter.id,
                          dismissControls: true,
                          showLoadingOverlay: true,
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        );
      },
    );
    final ReaderChapterAccessCoordinator? coordinator =
        _chapterAccessCoordinator;
    if (coordinator == null) return buildList();
    return AnimatedBuilder(
      animation: coordinator,
      builder: (BuildContext context, Widget? child) => buildList(),
    );
  }

  Widget _buildBookRefreshAction(
    int routeSession,
    String routeBookId, {
    String title = ReaderStrings.bookDetails,
  }) {
    if (widget.extensions.bookRefreshCapability == null) {
      return const SizedBox.shrink();
    }
    return ValueListenableBuilder<int>(
      valueListenable: _catalogRevision,
      builder: (BuildContext context, int revision, Widget? child) {
        final bool enabled =
            !_bookRefreshLoading &&
            _isRouteSessionCurrent(routeSession, routeBookId);
        return Padding(
          padding: const EdgeInsets.fromLTRB(18, 6, 12, 2),
          child: Row(
            children: <Widget>[
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
              const Spacer(),
              TextButton.icon(
                key: ValueKey<String>('reader-refresh-book-$title'),
                onPressed: enabled
                    ? () => unawaited(_refreshBookFromHost())
                    : null,
                icon: _bookRefreshLoading
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync_rounded, size: 18),
                label: Text(
                  _bookRefreshLoading ? '更新中' : ReaderStrings.refreshBook,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _centerCurrentCatalogChapterInView({
    required BuildContext sheetContext,
    required int routeSession,
    required String routeBookId,
    required TextReaderStateStore routeStore,
  }) {
    if (!_isRouteSessionCurrent(routeSession, routeBookId, store: routeStore)) {
      return;
    }
    final String? currentChapterId = _content?.chapterId;
    final String? chapterId = _logicalCatalogChapterId(currentChapterId);
    if (chapterId == null || chapterId == _centeredCatalogChapterId) {
      return;
    }
    final int chapterIndex = _catalog
        .where((chapter) => !chapter.isContinuation)
        .toList(growable: false)
        .indexWhere((ReaderChapterInfo chapter) => chapter.id == chapterId);
    if (_catalogLoading ||
        chapterIndex < 0 ||
        !sheetContext.mounted ||
        !_catalogScrollController.hasClients) {
      return;
    }
    final ScrollPosition position = _catalogScrollController.position;
    final double minimumVisibleOffset =
        (_catalogListTopPadding +
                (chapterIndex + 1) * _catalogChapterItemExtent -
                position.viewportDimension)
            .clamp(0, double.infinity);
    if (position.maxScrollExtent + 1 < minimumVisibleOffset) {
      // Retry after layout catches up with the completed catalog.
      if (_catalogCenterRetryCount >= 3) return;
      _catalogCenterRetryCount++;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _centerCurrentCatalogChapterInView(
          sheetContext: sheetContext,
          routeSession: routeSession,
          routeBookId: routeBookId,
          routeStore: routeStore,
        );
      });
      WidgetsBinding.instance.scheduleFrame();
      return;
    }
    _catalogCenterRetryCount = 0;
    final double centeredOffset =
        _catalogListTopPadding +
        chapterIndex * _catalogChapterItemExtent -
        (position.viewportDimension - _catalogChapterItemExtent) / 2;
    _catalogScrollController.jumpTo(
      centeredOffset.clamp(0, position.maxScrollExtent),
    );
    _centeredCatalogChapterId = chapterId;
  }

  String? _logicalCatalogChapterId(String? currentChapterId) {
    if (currentChapterId == null) return null;
    final int physicalIndex = _catalog.indexWhere(
      (chapter) => chapter.id == currentChapterId,
    );
    if (physicalIndex < 0 || !_catalog[physicalIndex].isContinuation) {
      return currentChapterId;
    }
    for (var index = physicalIndex - 1; index >= 0; index--) {
      if (!_catalog[index].isContinuation) return _catalog[index].id;
    }
    return _catalog.where((chapter) => !chapter.isContinuation).firstOrNull?.id;
  }
}
