/// 小说阅读器作品详情面板的布局。
///
/// 职责：组合宿主提供的作品元数据、封面和来源链接。
/// 注意：不拥有作品数据或封面缓存；数据由 _TextReaderViewState 持有。
part of 'text_reader_view.dart';

// ignore_for_file: invalid_use_of_protected_member

extension _TextReaderLibraryDetails on _TextReaderViewState {
  Widget _buildBookDetailTab(int routeSession, String routeBookId) {
    final ReaderBookInfo? book = _book;
    final List<String> labels = book == null
        ? const <String>[]
        : book.labels
              .map((String label) => label.trim())
              .where((String label) => label.isNotEmpty)
              .toSet()
              .take(8)
              .toList(growable: false);
    final int chapterCount = book?.chapterCount ?? _catalogTotal;
    final String? description = book?.description?.trim();
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
      children: <Widget>[
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _buildDetailHero(book, labels, routeSession, routeBookId),
                const SizedBox(height: 14),
                _buildDetailStats(book, chapterCount),
                if (description?.isNotEmpty == true) ...<Widget>[
                  const SizedBox(height: 14),
                  _buildDetailSection(
                    icon: Icons.notes_rounded,
                    title: '作品简介',
                    child: Text(
                      description!,
                      style: TextStyle(
                        color: _palette.secondaryText,
                        fontSize: 14,
                        height: 1.7,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                _buildDetailExternalRow(
                  icon: Icons.language_rounded,
                  title: '内容来源',
                  label: book?.sourceName ?? ReaderStrings.sourceUnavailable,
                  url: _sourceDisplayUri,
                ),
                if (book?.latestChapterTitle?.isNotEmpty == true) ...<Widget>[
                  const SizedBox(height: 10),
                  _buildDetailExternalRow(
                    icon: Icons.auto_stories_outlined,
                    title: '最新章节',
                    label: book!.latestChapterTitle!,
                    url: book.latestChapterUrl,
                  ),
                ],
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

  Widget _buildDetailHero(
    ReaderBookInfo? book,
    List<String> labels,
    int routeSession,
    String routeBookId,
  ) => Container(
    key: const ValueKey<String>('reader-book-detail-hero'),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: _palette.accent.withValues(alpha: .07),
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: _palette.accent.withValues(alpha: .18)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: _palette.accent.withValues(alpha: .14),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                Icons.local_library_outlined,
                size: 17,
                color: _palette.accent,
              ),
            ),
            const SizedBox(width: 9),
            const Expanded(
              child: Text(
                '作品信息',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
            ),
            _buildDetailRefreshButton(routeSession, routeBookId),
          ],
        ),
        const SizedBox(height: 14),
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final Widget metadata = _buildDetailMetadata(book, labels);
            if (constraints.maxWidth < 280) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Center(child: _buildDetailCover(book)),
                  const SizedBox(height: 16),
                  metadata,
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _buildDetailCover(book),
                const SizedBox(width: 16),
                Expanded(child: metadata),
              ],
            );
          },
        ),
      ],
    ),
  );

  Widget _buildDetailMetadata(ReaderBookInfo? book, List<String> labels) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            book?.title ?? ReaderStrings.bookPreview,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 22,
              height: 1.2,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 9),
          Row(
            children: <Widget>[
              Icon(
                Icons.person_outline_rounded,
                size: 16,
                color: _palette.secondaryText,
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  book?.author?.trim().isNotEmpty == true
                      ? book!.author!.trim()
                      : '作者未知',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: _palette.secondaryText, fontSize: 14),
                ),
              ),
            ],
          ),
          if (labels.isNotEmpty) ...<Widget>[
            const SizedBox(height: 14),
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: labels.map(_buildDetailTag).toList(growable: false),
            ),
          ],
        ],
      );

  Widget _buildDetailCover(ReaderBookInfo? book) => Semantics(
    image: true,
    label: '${book?.title ?? ReaderStrings.bookPreview}的封面',
    child: Container(
      key: const ValueKey<String>('reader-book-detail-cover'),
      width: 104,
      height: 156,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: .18),
            blurRadius: 18,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: _bookCoverImage == null
            ? _buildDetailCoverFallback(book)
            : Image(
                key: const ValueKey<String>('reader-book-detail-cover-image'),
                image: _bookCoverImage!,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
                gaplessPlayback: true,
                excludeFromSemantics: true,
                errorBuilder:
                    (BuildContext context, Object error, StackTrace? stack) =>
                        _buildDetailCoverFallback(book),
              ),
      ),
    ),
  );

  Widget _buildDetailCoverFallback(ReaderBookInfo? book) => Container(
    key: const ValueKey<String>('reader-book-detail-cover-placeholder'),
    padding: const EdgeInsets.all(11),
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: <Color>[
          _palette.accent.withValues(alpha: .94),
          Color.lerp(_palette.accent, _palette.text, .58)!,
        ],
      ),
    ),
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
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: _palette.panel.withValues(alpha: .72),
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: _palette.accent.withValues(alpha: .18)),
    ),
    child: Text(
      label,
      style: TextStyle(
        color: _palette.accent,
        fontSize: 11,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Widget _buildDetailStats(ReaderBookInfo? book, int chapterCount) {
    final String wordCount = _formatDetailWordCount(book?.wordCount);
    return Container(
      key: const ValueKey<String>('reader-book-detail-stats'),
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: _palette.panel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _palette.divider),
      ),
      child: Row(
        children: <Widget>[
          _buildDetailStat(wordCount, '字数'),
          SizedBox(
            height: 30,
            child: VerticalDivider(color: _palette.divider, width: 1),
          ),
          _buildDetailStat(chapterCount > 0 ? '$chapterCount' : '—', '章节'),
          SizedBox(
            height: 30,
            child: VerticalDivider(color: _palette.divider, width: 1),
          ),
          _buildDetailStat(
            book?.statusLabel?.trim().isNotEmpty == true
                ? book!.statusLabel!.trim()
                : '—',
            '状态',
          ),
        ],
      ),
    );
  }

  String _formatDetailWordCount(int? count) {
    if (count == null || count <= 0) return '—';
    if (count < 10000) return '$count';
    final double value = count / 10000;
    return '${value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toStringAsFixed(1)}万';
  }

  Widget _buildDetailStat(String value, String label) => Expanded(
    child: Column(
      children: <Widget>[
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          style: TextStyle(color: _palette.secondaryText, fontSize: 11),
        ),
      ],
    ),
  );

  Widget _buildDetailSection({
    required IconData icon,
    required String title,
    required Widget child,
  }) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: _palette.panel,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: _palette.divider),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(icon, size: 18, color: _palette.accent),
            const SizedBox(width: 8),
            Text(
              title,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
          ],
        ),
        const SizedBox(height: 10),
        child,
      ],
    ),
  );

  Widget _buildDetailExternalRow({
    required IconData icon,
    required String title,
    required String label,
    required Uri? url,
  }) {
    final VoidCallback? openSourceAction = url == null
        ? null
        : () => unawaited(_openSourceUrl(url));
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: _palette.panel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _palette.divider),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: _palette.accent.withValues(alpha: .1),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(icon, size: 19, color: _palette.accent),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(color: _palette.secondaryText, fontSize: 11),
                ),
                const SizedBox(height: 3),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          if (url != null)
            ReaderAccessibleTooltip(
              label: ReaderStrings.openSourceUrl,
              onTap: openSourceAction!,
              child: MotionIconButtonSurface(
                child: IconButton(
                  onPressed: openSourceAction,
                  icon: Icon(
                    Icons.open_in_new_rounded,
                    size: 20,
                    color: _palette.accent,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDetailRefreshButton(int routeSession, String routeBookId) {
    if (widget.extensions.bookRefreshCapability == null) {
      return const SizedBox.shrink();
    }
    return ValueListenableBuilder<int>(
      valueListenable: _catalogRevision,
      builder: (BuildContext context, int revision, Widget? child) {
        final bool enabled =
            !_bookRefreshLoading &&
            _isRouteSessionCurrent(routeSession, routeBookId);
        return ReaderAccessibleTooltip(
          label: ReaderStrings.refreshBook,
          onTap: () {
            if (enabled) unawaited(_refreshBookFromHost());
          },
          child: MotionIconButtonSurface(
            child: IconButton(
              key: const ValueKey<String>('reader-refresh-book-detail'),
              visualDensity: VisualDensity.compact,
              onPressed: enabled
                  ? () => unawaited(_refreshBookFromHost())
                  : null,
              icon: _bookRefreshLoading
                  ? const SizedBox.square(
                      dimension: 17,
                      child: MotionCircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync_rounded, size: 19),
            ),
          ),
        );
      },
    );
  }
}
