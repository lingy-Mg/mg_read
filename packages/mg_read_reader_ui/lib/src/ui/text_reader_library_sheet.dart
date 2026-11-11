/// 小说阅读器作品库弹层入口和路由生命周期。
///
/// 职责：创建详情、目录和书签标签页，并在会话变化时隔离异步更新。
/// 注意：具体内容由同一 library 的详情、目录和书签 part 负责。
part of 'text_reader_view.dart';

// ignore_for_file: invalid_use_of_protected_member

extension _TextReaderLibrarySheet on _TextReaderViewState {
  void _showLibrarySheet({int initialIndex = 1}) {
    _stopAutoReading();
    final int routeSession = _sessionGeneration;
    final String routeBookId = widget.bookId;
    final TextReaderStateStore routeStore = widget.stateStore;
    // Keep the last catalog location when the sheet is reopened or when the
    // user switches between its tabs. A new reader session resets this in
    // _restart, while a chapter change still recenters on the new chapter.
    _catalogCenterRetryCount = 0;
    bool sheetRefreshStarted = false;
    final ThemeData readerTheme = readerThemeData(
      _palette,
      font: _preferences.font,
    );
    showModalBottomSheet<void>(
      context: context,
      sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : null,
      isScrollControlled: true,
      isDismissible: true,
      enableDrag: true,
      backgroundColor: Colors.transparent,
      barrierColor: ReaderSettingsTokens.sheetBarrier(_palette),
      builder: (BuildContext sheetContext) {
        return Theme(
          data: readerTheme,
          child: StatefulBuilder(
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
                                      child: PageStorage(
                                        bucket: _catalogPageStorageBucket,
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
          ),
        );
      },
    );
  }
}
