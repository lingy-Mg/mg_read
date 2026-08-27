part of 'text_reader_view.dart';

/// 组合纵向滚动正文、评论占位和下一章入口。
extension _TextReaderVerticalContentWidgets on _TextReaderViewState {
  Widget _buildVerticalReader() {
    final List<TextParagraph> paragraphs = _content!.paragraphs;
    final bool showChapterComments =
        widget.extensions.commentFeed != null &&
        _preferences.showChapterComments;
    final bool showParagraphComments =
        widget.extensions.commentFeed != null &&
        _preferences.showParagraphComments;
    final int chapterSummaryIndex = paragraphs.length + 1;
    final int nextChapterIndex =
        chapterSummaryIndex + (showChapterComments ? 1 : 0);
    return GestureDetector(
      key: const ValueKey<String>('reader-content-surface'),
      behavior: HitTestBehavior.translucent,
      onTapUp: (_) {
        if (_readerInteractionBlocked) {
          if (_readerSettingsVisible) {
            _dismissReaderSettingsFromReader();
          } else {
            _dismissReaderControlsFromReader();
          }
          return;
        }
        _stopAutoReading();
        _setControlsVisible(!_controlsVisible);
      },
      child: SafeArea(
        child: NotificationListener<UserScrollNotification>(
          onNotification: (UserScrollNotification notification) {
            if (!_autoScrolling &&
                notification.direction != ScrollDirection.idle) {
              _stopAutoReading();
            }
            return false;
          },
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final double contentWidth =
                  (constraints.maxWidth - _preferences.horizontalPadding * 2)
                      .clamp(1, constraints.maxWidth.clamp(1, double.infinity));
              _prepareVerticalItemExtents(
                width: contentWidth,
                textDirection: Directionality.of(context),
                itemCount: nextChapterIndex + 1,
                hasParagraphComments: showParagraphComments,
                hasChapterComments: showChapterComments,
              );
              return ListView.builder(
                controller: _verticalController,
                physics: _readerInteractionBlocked
                    ? const NeverScrollableScrollPhysics()
                    : null,
                padding: EdgeInsets.fromLTRB(
                  _preferences.horizontalPadding,
                  _preferences.topPadding,
                  _preferences.horizontalPadding,
                  _preferences.bottomPadding,
                ),
                itemCount: nextChapterIndex + 1,
                itemExtentBuilder: (int index, _) => _verticalItemExtent(index),
                itemBuilder: (BuildContext context, int index) {
                  if (index == 0) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 28),
                      child: Text(
                        _content!.title,
                        style: _titleTextStyle,
                        textScaler: _textScaler,
                      ),
                    );
                  }
                  if (index <= paragraphs.length) {
                    final TextParagraph paragraph = paragraphs[index - 1];
                    final ReaderCommentTarget target =
                        ReaderCommentTarget.paragraph(
                          widget.bookId,
                          _content!.chapterId,
                          paragraph.id,
                        );
                    return Column(
                      key: _paragraphKey(paragraph.id),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Padding(
                          padding: EdgeInsets.only(
                            bottom: _preferences.paragraphSpacing,
                          ),
                          child: Text.rich(
                            TextSpan(
                              style: _bodyTextStyle,
                              children: <InlineSpan>[
                                TextSpan(text: _indented(paragraph.text)),
                                if (showParagraphComments)
                                  WidgetSpan(
                                    alignment: PlaceholderAlignment.middle,
                                    child: _inlineParagraphComment(
                                      target: target,
                                      onPressed: () => _showComments(
                                        target,
                                        title:
                                            ReaderCommentStrings.paragraphTitle,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            textScaler: _textScaler,
                          ),
                        ),
                      ],
                    );
                  }
                  if (showChapterComments && index == chapterSummaryIndex) {
                    return _buildChapterCommentSummary();
                  }
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: OutlinedButton(
                      onPressed: _nextChapter,
                      child: const Text(ReaderStrings.nextChapter),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}
