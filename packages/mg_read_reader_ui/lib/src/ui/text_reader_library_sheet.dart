part of 'text_reader_view.dart';

// ignore_for_file: invalid_use_of_protected_member

extension _TextReaderLibrarySheet on _TextReaderViewState {
  void _showLibrarySheet({int initialIndex = 1}) {
    _stopAutoReading();
    unawaited(_refreshLoadedChapterStates());
    final int routeSession = _sessionGeneration;
    final String routeBookId = widget.bookId;
    final TextReaderStateStore routeStore = widget.stateStore;
    _centeredCatalogChapterId = null;
    bool sheetRefreshStarted = false;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      isDismissible: true,
      enableDrag: true,
      backgroundColor: Colors.transparent,
      barrierColor: ReaderSettingsTokens.sheetBarrier(_palette),
      builder: (BuildContext sheetContext) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setSheetState) {
            if (!sheetRefreshStarted) {
              sheetRefreshStarted = true;
              WidgetsBinding.instance.addPostFrameCallback((_) async {
                if (!_isRouteSessionCurrent(
                  routeSession,
                  routeBookId,
                  store: routeStore,
                )) {
                  return;
                }
                await _refreshCommentSummaries();
                if (sheetContext.mounted &&
                    _isRouteSessionCurrent(
                      routeSession,
                      routeBookId,
                      store: routeStore,
                    )) {
                  setSheetState(() {});
                }
              });
            }
            final MediaQueryData mediaQuery = MediaQuery.of(context);
            final double sheetHeight = (mediaQuery.size.height * 0.74)
                .clamp(0, 640)
                .toDouble();
            return MediaQuery(
              data: mediaQuery.copyWith(
                textScaler: mediaQuery.textScaler.clamp(maxScaleFactor: 1.3),
              ),
              // Limit the route child to the visible panel so the uncovered
              // reader area remains the tappable modal barrier.
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
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(20),
                        ),
                        child: Material(
                          color: _palette.panel,
                          child: SafeArea(
                            top: false,
                            child: DefaultTabController(
                              length: 3,
                              initialIndex: initialIndex,
                              child: Column(
                                children: <Widget>[
                                  const SizedBox(height: 8),
                                  Container(
                                    width: 34,
                                    height: 4,
                                    decoration: BoxDecoration(
                                      color: _palette.divider,
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  const TabBar(
                                    dividerHeight: 1,
                                    labelStyle: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    tabs: <Widget>[
                                      Tab(text: ReaderStrings.bookDetails),
                                      Tab(text: ReaderStrings.catalog),
                                      Tab(text: ReaderStrings.bookmarks),
                                    ],
                                  ),
                                  Expanded(
                                    child: TabBarView(
                                      children: <Widget>[
                                        _buildBookDetailTab(
                                          routeSession,
                                          routeBookId,
                                        ),
                                        _buildCatalogList(
                                          sheetContext,
                                          routeSession,
                                          routeBookId,
                                          routeStore,
                                        ),
                                        _buildBookmarkList(
                                          sheetContext,
                                          routeSession,
                                          routeBookId,
                                          routeStore,
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
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
  }

  Widget _buildBookDetailTab(int routeSession, String routeBookId) {
    final ReaderBookInfo? book = _book;
    final List<String> labels = book == null
        ? const <String>[]
        : book.labels
              .where((label) => label.trim().isNotEmpty)
              .take(6)
              .toList();
    final int chapterCount = book?.chapterCount ?? _catalogTotal;
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 24),
      children: <Widget>[
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _buildDetailCover(book),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            book?.title ?? ReaderStrings.bookPreview,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 22,
                              height: 1.15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            book?.author?.isNotEmpty == true
                                ? book!.author!
                                : '作者未知',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: _palette.secondaryText,
                              fontSize: 14,
                            ),
                          ),
                          if (labels.isNotEmpty) ...<Widget>[
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: labels
                                  .map(_buildDetailTag)
                                  .toList(growable: false),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _buildDetailStats(book, chapterCount),
                const SizedBox(height: 12),
                _buildDetailExternalRow(
                  icon: Icons.language_rounded,
                  title: '来源频道',
                  label: book?.sourceName ?? ReaderStrings.sourceUnavailable,
                  url: _sourceDisplayUri,
                ),
                if (book?.description?.isNotEmpty == true) ...<Widget>[
                  const SizedBox(height: 20),
                  Divider(color: _palette.divider, height: 1),
                  const SizedBox(height: 18),
                  const Text(
                    '简介',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    book!.description!,
                    style: TextStyle(
                      color: _palette.secondaryText,
                      fontSize: 14,
                      height: 1.65,
                    ),
                  ),
                ],
                if (book?.latestChapterTitle?.isNotEmpty == true) ...<Widget>[
                  const SizedBox(height: 18),
                  _buildDetailExternalRow(
                    icon: Icons.auto_stories_outlined,
                    title: '最新章节',
                    label: book!.latestChapterTitle!,
                    url: book.latestChapterUrl,
                  ),
                ],
                const SizedBox(height: 18),
                _buildDetailExternalRow(
                  icon: Icons.menu_book_outlined,
                  title: '阅读来源',
                  label: book?.sourceName ?? ReaderStrings.sourceUnavailable,
                  url: _sourceDisplayUri,
                ),
                if (widget.extensions.commentFeed != null &&
                    _preferences.showBookComments) ...<Widget>[
                  const SizedBox(height: 16),
                  _buildBookCommentSummary(
                    target: ReaderCommentTarget.book(routeBookId),
                    onPressed: () {
                      if (!_isRouteSessionCurrent(routeSession, routeBookId)) {
                        return;
                      }
                      _showComments(
                        ReaderCommentTarget.book(routeBookId),
                        title: ReaderCommentStrings.bookTitle,
                      );
                    },
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDetailCover(ReaderBookInfo? book) => Container(
    width: 96,
    height: 146,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(12),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: <Color>[
          _palette.accent.withValues(alpha: .92),
          _palette.text.withValues(alpha: .78),
        ],
      ),
      boxShadow: <BoxShadow>[
        BoxShadow(
          color: Colors.black.withValues(alpha: .16),
          blurRadius: 14,
          offset: const Offset(0, 6),
        ),
      ],
    ),
    padding: const EdgeInsets.all(10),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        const Icon(Icons.menu_book_rounded, size: 30, color: Colors.white),
        const SizedBox(height: 8),
        Text(
          book?.title ?? ReaderStrings.bookPreview,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            height: 1.2,
          ),
        ),
      ],
    ),
  );

  Widget _buildDetailTag(String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: _palette.accent.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(label, style: TextStyle(color: _palette.accent, fontSize: 11)),
  );

  Widget _buildDetailStats(ReaderBookInfo? book, int chapterCount) {
    final String wordCount = book?.wordCount == null
        ? '—'
        : '${(book!.wordCount! / 10000).toStringAsFixed(1)}万';
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: Border.symmetric(
          horizontal: BorderSide(color: _palette.divider),
        ),
      ),
      child: Row(
        children: <Widget>[
          _buildDetailStat(wordCount, '字数'),
          _buildDetailStat(chapterCount > 0 ? '$chapterCount' : '—', '章节'),
          _buildDetailStat(book?.statusLabel ?? '—', '状态'),
        ],
      ),
    );
  }

  Widget _buildDetailStat(String value, String label) => Expanded(
    child: Column(
      children: <Widget>[
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          style: TextStyle(color: _palette.secondaryText, fontSize: 11),
        ),
      ],
    ),
  );

  Widget _buildDetailExternalRow({
    required IconData icon,
    required String title,
    required String label,
    required Uri? url,
  }) {
    final String? value = url?.toString();
    return Row(
      children: <Widget>[
        Icon(icon, size: 18, color: _palette.secondaryText),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                style: TextStyle(color: _palette.secondaryText, fontSize: 11),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
            ],
          ),
        ),
        if (url != null)
          IconButton(
            tooltip: ReaderStrings.openSourceUrl,
            onPressed: () => unawaited(_openSourceUrl(url)),
            icon: Icon(Icons.open_in_new_rounded, color: _palette.accent),
          )
        else
          Text(
            value ?? ReaderStrings.sourceUrlUnavailable,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: _palette.secondaryText, fontSize: 11),
          ),
      ],
    );
  }

  Widget _buildCatalogList(
    BuildContext sheetContext,
    int routeSession,
    String routeBookId,
    TextReaderStateStore routeStore,
  ) {
    final String? currentChapterId = _content?.chapterId;
    Widget buildList() => StatefulBuilder(
      builder: (BuildContext context, StateSetter setSheetState) {
        if (_catalog.isEmpty && !_catalogHasMore && !_catalogLoading) {
          return _ReaderEmptyState(
            icon: Icons.menu_book_outlined,
            message: ReaderStrings.noChapters,
            color: _palette.secondaryText,
          );
        }
        if (currentChapterId != null && _centeredCatalogChapterId != currentChapterId) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _centerCurrentCatalogChapterInView(
              sheetContext: sheetContext,
              routeSession: routeSession,
              routeBookId: routeBookId,
              routeStore: routeStore,
            );
          });
        }
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
          itemCount: _catalog.length + (_catalogHasMore ? 1 : 0),
          itemBuilder: (BuildContext context, int index) {
            if (index == _catalog.length) {
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
                          await _loadMoreCatalog();
                          if (!sheetContext.mounted ||
                              !_isRouteSessionCurrent(
                                routeSession,
                                routeBookId,
                                store: routeStore,
                              )) {
                            return;
                          }
                          setSheetState(() {});
                        },
                  child: Text(
                    _catalogLoading
                        ? ReaderStrings.loading
                        : ReaderStrings.loadMoreChapters,
                  ),
                ),
              );
            }
            final ReaderChapterInfo chapter = _catalog[index];
            final bool isCurrentChapter = chapter.id == currentChapterId;
            final GlobalKey chapterItemKey = _catalogItemKeys.putIfAbsent(
              chapter.id,
              () => GlobalKey(),
            );
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
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: ListTile(
                  key: chapterItemKey,
                  dense: true,
                  visualDensity: const VisualDensity(vertical: -1),
                  minVerticalPadding: 4,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  tileColor: isCurrentChapter
                      ? _palette.accent.withValues(alpha: .14)
                      : index.isEven
                      ? _palette.accent.withValues(alpha: .035)
                      : null,
                  selected: isCurrentChapter,
                  selectedColor: _palette.accent,
                  selectedTileColor: _palette.accent.withValues(alpha: .15),
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(Radius.circular(14)),
                  ),
                  leading: SizedBox(
                    width: 34,
                    child: Text(
                      '${chapter.index + 1}',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: isCurrentChapter
                            ? _palette.accent
                            : _palette.secondaryText,
                        fontSize: isCurrentChapter ? 12.5 : 12,
                        fontWeight: isCurrentChapter
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
                      fontSize: isCurrentChapter ? 14.5 : 14,
                      fontWeight: isCurrentChapter
                          ? FontWeight.w700
                          : FontWeight.w500,
                      color: isCurrentChapter ? _palette.accent : null,
                    ),
                  ),
                  trailing: isCurrentChapter
                      ? Icon(
                          Icons.play_arrow_rounded,
                          size: 16,
                          color: _palette.accent,
                        )
                      : null,
                  subtitle: ReaderChapterStateBadge(
                    availability: availability,
                    wordCount:
                        !stateLoading &&
                            availability == ReaderChapterAvailability.downloaded
                        ? wordCount
                        : null,
                    hasBeenRead: hasBeenRead,
                    loading: stateLoading && refreshedState == null,
                    palette: _palette,
                    onRetry: availability == ReaderChapterAvailability.failed
                        ? () => unawaited(
                            _refreshLoadedChapterStates(chapterId: chapter.id),
                          )
                        : null,
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
                    unawaited(_openChapter(chapter.id));
                  },
                ),
              ),
            );
          },
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

  void _centerCurrentCatalogChapterInView({
    required BuildContext sheetContext,
    required int routeSession,
    required String routeBookId,
    required TextReaderStateStore routeStore,
  }) {
    if (!_isRouteSessionCurrent(
      routeSession,
      routeBookId,
      store: routeStore,
    )) {
      return;
    }
    final String? chapterId = _content?.chapterId;
    if (chapterId == null || chapterId == _centeredCatalogChapterId) {
      return;
    }
    final BuildContext? chapterItemContext = _catalogItemKeys[chapterId]
        ?.currentContext;
    if (chapterItemContext == null || !sheetContext.mounted) return;
    if (Scrollable.maybeOf(chapterItemContext) == null) return;
    _centeredCatalogChapterId = chapterId;
    unawaited(
      Scrollable.ensureVisible(
        chapterItemContext,
        alignment: 0.5,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  Widget _buildBookmarkList(
    BuildContext sheetContext,
    int routeSession,
    String routeBookId,
    TextReaderStateStore routeStore,
  ) {
    if (_bookmarks.isEmpty) {
      return _ReaderEmptyState(
        icon: Icons.bookmark_border_rounded,
        message: ReaderStrings.noBookmarks,
        color: _palette.secondaryText,
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
      itemCount: _bookmarks.length,
      itemBuilder: (BuildContext context, int index) {
        final ReaderBookmark bookmark = _bookmarks[index];
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              leading: Icon(
                Icons.bookmark_outline_rounded,
                size: 20,
                color: _palette.accent,
              ),
              title: Text(bookmark.chapterTitle),
              subtitle: Text(
                bookmark.excerpt,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                tooltip: ReaderStrings.removeBookmark,
                icon: const Icon(Icons.close_rounded, size: 19),
                onPressed: () async {
                  await _queueBookmarkMutation(() async {
                    if (!_isRouteSessionCurrent(
                          routeSession,
                          routeBookId,
                          store: routeStore,
                        ) ||
                        _bookmarks.every((item) => item.id != bookmark.id)) {
                      return;
                    }
                    try {
                      await routeStore.removeBookmark(routeBookId, bookmark.id);
                    } catch (error) {
                      if (_isRouteSessionCurrent(
                        routeSession,
                        routeBookId,
                        store: routeStore,
                      )) {
                        await _reportFailure(
                          _asFailure(error, ReaderFailureKind.persistence),
                        );
                      }
                      return;
                    }
                    if (!sheetContext.mounted ||
                        !_isRouteSessionCurrent(
                          routeSession,
                          routeBookId,
                          store: routeStore,
                        )) {
                      return;
                    }
                    setState(() {
                      _bookmarks = List.unmodifiable(
                        _bookmarks.where((item) => item.id != bookmark.id),
                      );
                    });
                    Navigator.of(sheetContext).pop();
                  });
                },
              ),
              onTap: () {
                if (!_isRouteSessionCurrent(
                      routeSession,
                      routeBookId,
                      store: routeStore,
                    ) ||
                    bookmark.bookId != routeBookId) {
                  return;
                }
                _progress = ReaderProgress(
                  chapterId: bookmark.chapterId,
                  paragraphId: bookmark.paragraphId,
                  characterOffset: bookmark.characterOffset,
                );
                Navigator.of(sheetContext).pop();
                unawaited(_openChapter(bookmark.chapterId, initial: true));
              },
            ),
          ),
        );
      },
    );
  }
}
