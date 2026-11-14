/// 小说阅读器书签列表。
///
/// 职责：展示书签、请求删除或恢复章节位置。
/// 注意：持久化经宿主 TextReaderStateStore 完成，回调校验路由会话。
part of 'text_reader_view.dart';

// ignore_for_file: invalid_use_of_protected_member

extension _TextReaderLibraryBookmarks on _TextReaderViewState {
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
        Future<void> removeBookmark() async {
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
        }

        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: MotionListTile(
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
              trailing: ReaderAccessibleTooltip(
                label: ReaderStrings.removeBookmark,
                onTap: removeBookmark,
                child: MotionIconButtonSurface(
                  child: IconButton(
                    key: ValueKey<String>(
                      'reader-bookmark-remove-${bookmark.id}',
                    ),
                    icon: const Icon(Icons.close_rounded, size: 19),
                    onPressed: removeBookmark,
                  ),
                ),
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
                final ReaderProgress restoreProgress = ReaderProgress(
                  chapterId: bookmark.chapterId,
                  paragraphId: bookmark.paragraphId,
                  characterOffset: bookmark.characterOffset,
                );
                Navigator.of(sheetContext).pop();
                unawaited(
                  _openChapter(
                    bookmark.chapterId,
                    dismissControls: true,
                    showLoadingOverlay: true,
                    restoreProgress: restoreProgress,
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}
