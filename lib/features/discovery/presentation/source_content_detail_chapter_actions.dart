part of 'source_content_detail_sheet.dart';

/// External links, chapter rows, and media-specific chapter dispatch.
class _ExternalRow extends StatelessWidget {
  const _ExternalRow({required this.label, required this.url, required this.onOpenUrl, this.title, this.subtitle, super.key});
  final String? title;
  final String label;
  final String? subtitle;
  final Uri? url;
  final Future<void> Function(BuildContext context, Uri? url) onOpenUrl;
  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final theme = Theme.of(context);
    final enabled = _isOpenableExternalUrl(url);
    final disabledTextColor = tokens.mutedText;
    return Semantics(
      button: enabled,
      enabled: enabled,
      label: title == null ? label : '$title，$label',
      child: InkWell(
        onTap: enabled ? () => unawaited(onOpenUrl(context, url)) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.regular),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    if (title != null)
                      Text(
                        title!,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: enabled ? null : disabledTextColor,
                        ),
                      ),
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: enabled ? null : TextStyle(color: disabledTextColor),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: enabled ? disabledTextColor : disabledTextColor.withValues(alpha: .68),
                        ),
                      ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: enabled ? disabledTextColor : disabledTextColor.withValues(alpha: .5)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChapterRow extends StatelessWidget {
  const _ChapterRow({required this.chapter, required this.onRead, required this.onOpenUrl});
  final PluginChapterSummary chapter;
  final VoidCallback onRead;
  final Future<void> Function(BuildContext context, Uri? url) onOpenUrl;
  @override
  Widget build(BuildContext context) => ListTile(
    key: ValueKey<String>('source-chapter-${chapter.id}'),
    contentPadding: EdgeInsets.zero,
    title: Text(chapter.title),
    subtitle: Text(_chapterSubtitle(chapter)),
    trailing: !_isOpenableExternalUrl(chapter.url)
        ? Icon(Icons.chevron_right_rounded, color: AppThemeTokens.of(context).mutedText)
        : IconButton(
            key: ValueKey<String>('source-chapter-url-${chapter.id}'),
            tooltip: '在浏览器打开章节',
            onPressed: () => unawaited(onOpenUrl(context, chapter.url)),
            icon: const Icon(Icons.open_in_browser_rounded),
          ),
    onTap: onRead,
  );
}

bool _isOpenableExternalUrl(Uri? url) => url != null && (url.scheme == 'http' || url.scheme == 'https');

Future<void> _openTextChapter(
  BuildContext context, {
  required SourceContentGateway gateway,
  required PluginContentDetail detail,
  required PluginChaptersResult firstCatalogPage,
  required PluginChapterSummary chapter,
  required SourceTextChapterRequested? onTextChapterRequested,
  required SourceComicChapterRequested? onComicChapterRequested,
  required SourceAudioChapterRequested? onAudioChapterRequested,
  required SourceVideoEpisodeRequested? onVideoEpisodeRequested,
}) async {
  // The detail route is the stable return destination for all four content
  // types. The app host pushes a reader/player above this route, so do not
  // dismiss the detail before invoking its callback. Doing so skips the detail
  // on exit and can also desynchronise discovery's retained category routes.
  if (!context.mounted || ModalRoute.of(context)?.isCurrent == false) return;
  if (detail.summary.contentKind == PluginContentKind.audio) {
    final callback = onAudioChapterRequested;
    if (callback == null) {
      throw StateError('An audio-player host has not been registered.');
    }
    // Audio and video entry covers live on detail.summary. Both branches must
    // attach the resolved bytes before entering their host-owned surface.
    final playbackDetail = _withResolvedEntryCover(detail, context);
    final pluginVersion = BookCoverSourceScope.maybeOf(context)?.pluginVersion ?? 'unknown';
    await callback(detail: playbackDetail, firstCatalogPage: firstCatalogPage, chapter: chapter, pluginVersion: pluginVersion);
    return;
  }
  if (detail.summary.contentKind == PluginContentKind.video) {
    final callback = onVideoEpisodeRequested;
    if (callback == null) {
      throw StateError('A video-player host has not been registered.');
    }
    // The detail cover is commonly resolved by DiscoveryBookCover and kept in
    // the route-to-route memory cache. Carry it across the detail-to-player
    // handoff so the player can show the real artwork immediately instead of
    // its fallback.
    final playbackDetail = _withResolvedEntryCover(detail, context);
    await callback(detail: playbackDetail, firstCatalogPage: firstCatalogPage, chapter: chapter);
    return;
  }
  if (detail.summary.contentKind == PluginContentKind.manga) {
    final callback = onComicChapterRequested;
    if (callback == null) {
      await _showChapterContent(context, gateway: gateway, pluginId: detail.pluginId, id: detail.summary.id, chapter: chapter);
      return;
    }
    final entryCoverBytes = _resolvedEntryCoverBytes(context, detail.summary);
    await callback(detail: detail, firstCatalogPage: firstCatalogPage, chapter: chapter, entryCoverBytes: entryCoverBytes);
    return;
  }
  final callback = onTextChapterRequested;
  if (callback == null) {
    await _showChapterContent(context, gateway: gateway, pluginId: detail.pluginId, id: detail.summary.id, chapter: chapter);
    return;
  }
  final entryCoverBytes = _resolvedEntryCoverBytes(context, detail.summary);
  await callback(detail: detail, firstCatalogPage: firstCatalogPage, chapter: chapter, entryCoverBytes: entryCoverBytes);
}

List<int>? _resolvedEntryCoverBytes(BuildContext context, PluginContentSummary content) {
  final supplied = content.coverBytes;
  if (supplied != null && supplied.isNotEmpty) return supplied;
  final coverUrl = content.coverUrl;
  final scope = context.getInheritedWidgetOfExactType<BookCoverSourceScope>();
  if (coverUrl == null || scope == null) return null;
  return BookCoverMemoryCache.peek(scope.requestFor(remoteContentId: content.id, coverUrl: coverUrl));
}

PluginContentDetail _withResolvedEntryCover(PluginContentDetail detail, BuildContext context) {
  return preserveSourceContentCover(detail: detail, resolvedCoverBytes: _resolvedEntryCoverBytes(context, detail.summary));
}

Future<void> _showChapterContent(
  BuildContext context, {
  required SourceContentGateway gateway,
  required String pluginId,
  required String id,
  required PluginChapterSummary chapter,
}) {
  final contentFuture = gateway.getContent(pluginId: pluginId, id: id, chapterId: chapter.id);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => FractionallySizedBox(
      heightFactor: .9,
      child: FutureBuilder<PluginChapterContent>(
        future: contentFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _DetailFailure(error: AppError.fromUnknown(snapshot.error!), pluginId: pluginId, contentId: id, chapterId: chapter.id);
          }
          final content = snapshot.requireData;
          return ListView(
            key: const Key('source-chapter-content-sheet'),
            padding: const EdgeInsets.all(AppSpacing.comfortable),
            children: <Widget>[
              Text(content.title ?? chapter.title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: AppSpacing.regular),
              if (content.contentKind == PluginContentKind.novel)
                SelectableText(content.text ?? '')
              else
                for (final page in content.pages)
                  _ExternalRow(
                    label: '第 ${page.index + 1} 页',
                    subtitle: _mangaPageSubtitle(page),
                    url: page.url,
                    onOpenUrl: (context, url) async {
                      if (url != null) await _launchSystemBrowser(url);
                    },
                  ),
            ],
          );
        },
      ),
    ),
  );
}
