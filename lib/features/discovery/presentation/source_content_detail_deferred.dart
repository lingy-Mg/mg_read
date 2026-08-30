/// 书架详情的本地优先延迟装载层。
///
/// 职责：
/// - 长按后立即显示内存中的书架摘要和定制操作栏。
/// - 异步接入持久化目录预览，再交给共享详情页后台刷新数据源内容。
///
/// 注意：
/// - 本层不访问数据库或 Runtime；所有 IO 由传入 Future 与 gateway 持有。
/// - 本地种子失败时保留可操作的缓存预览，不让面板退化为无响应状态。
part of 'source_content_detail_sheet.dart';

/// Local-first inputs resolved from a persisted shelf item.
final class SourceContentDetailSeed {
  const SourceContentDetailSeed({
    required this.pluginId,
    required this.id,
    required this.initialContent,
    required this.initialCatalog,
    required this.sourceName,
  });

  final String pluginId;
  final String id;
  final PluginContentSummary initialContent;
  final PluginChaptersResult initialCatalog;
  final String sourceName;
}

/// Opens the shelf detail surface immediately, then replaces its in-memory
/// preview with the persisted seed and finally refreshes from the source.
Future<void> showDeferredSourceContentDetailSheet(
  BuildContext context, {
  required Future<SourceContentDetailSeed> seed,
  required PluginContentSummary previewContent,
  required SourceContentGateway gateway,
  required SourceDetailShelfState shelfState,
  required SourceShelfActionRequested onShelfAction,
  required SourceStartReadingRequested onStartReading,
  SourceTextChapterRequested? onTextChapterRequested,
  SourceComicChapterRequested? onComicChapterRequested,
  SourceAudioChapterRequested? onAudioChapterRequested,
  SourceVideoEpisodeRequested? onVideoEpisodeRequested,
  SourceExternalUrlLauncher? onExternalUrlRequested,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.92,
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        child: _DeferredSourceDetailScreen(
          seed: seed,
          previewContent: previewContent,
          gateway: gateway,
          shelfState: shelfState,
          onShelfAction: onShelfAction,
          onStartReading: onStartReading,
          onTextChapterRequested: onTextChapterRequested,
          onComicChapterRequested: onComicChapterRequested,
          onAudioChapterRequested: onAudioChapterRequested,
          onVideoEpisodeRequested: onVideoEpisodeRequested,
          onExternalUrlRequested: onExternalUrlRequested ?? _launchSystemBrowser,
        ),
      ),
    ),
  );
}

class _DeferredSourceDetailScreen extends StatelessWidget {
  const _DeferredSourceDetailScreen({
    required this.seed,
    required this.previewContent,
    required this.gateway,
    required this.shelfState,
    required this.onShelfAction,
    required this.onStartReading,
    required this.onTextChapterRequested,
    required this.onComicChapterRequested,
    required this.onAudioChapterRequested,
    required this.onVideoEpisodeRequested,
    required this.onExternalUrlRequested,
  });

  final Future<SourceContentDetailSeed> seed;
  final PluginContentSummary previewContent;
  final SourceContentGateway gateway;
  final SourceDetailShelfState shelfState;
  final SourceShelfActionRequested onShelfAction;
  final SourceStartReadingRequested onStartReading;
  final SourceTextChapterRequested? onTextChapterRequested;
  final SourceComicChapterRequested? onComicChapterRequested;
  final SourceAudioChapterRequested? onAudioChapterRequested;
  final SourceVideoEpisodeRequested? onVideoEpisodeRequested;
  final SourceExternalUrlLauncher onExternalUrlRequested;

  _SourceDetailBundle get _previewBundle => _SourceDetailBundle(
    detail: PluginContentDetail(
      pluginId: 'library-preview',
      sourceName: '书架缓存',
      summary: previewContent,
      aliases: const <String>[],
      catalogUrl: previewContent.url,
    ),
    chapters: PluginChaptersResult(pluginId: 'library-preview', sourceName: '书架缓存', items: const <PluginChapterSummary>[]),
  );

  @override
  Widget build(BuildContext context) => FutureBuilder<SourceContentDetailSeed>(
    future: seed,
    builder: (context, snapshot) {
      if (snapshot.hasData) {
        final data = snapshot.requireData;
        return _SourceDetailScreen(
          gateway: gateway,
          pluginId: data.pluginId,
          id: data.id,
          initialContent: data.initialContent,
          initialCatalog: data.initialCatalog,
          initialSourceName: data.sourceName,
          relatedContents: const <PluginContentSummary>[],
          onTextChapterRequested: onTextChapterRequested,
          onComicChapterRequested: onComicChapterRequested,
          onAudioChapterRequested: onAudioChapterRequested,
          onVideoEpisodeRequested: onVideoEpisodeRequested,
          onAddToShelf: null,
          onRemoveFromShelf: null,
          shelfState: shelfState,
          onExternalUrlRequested: onExternalUrlRequested,
          onShelfAction: onShelfAction,
          onStartReading: onStartReading,
          isModalSheet: true,
        );
      }
      return Scaffold(
        body: SafeArea(
          child: Column(
            children: <Widget>[
              const Padding(
                padding: EdgeInsets.only(top: 10, bottom: 2),
                child: SizedBox(
                  width: 42,
                  height: 5,
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.all(Radius.circular(99))),
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  AppSpacing.discoveryPagePadding,
                  AppSpacing.pageHeaderTopPaddingFor(context),
                  AppSpacing.discoveryPagePadding,
                  AppSpacing.pageHeaderTopPadding,
                ),
                child: _DetailHeader(isModalSheet: true),
              ),
              Expanded(
                child: _SourceDetailView(
                  key: const ValueKey<String>('source-detail-deferred-preview'),
                  bundle: _previewBundle,
                  gateway: gateway,
                  relatedContents: const <PluginContentSummary>[],
                  isRefreshing: !snapshot.hasError,
                  onTextChapterRequested: onTextChapterRequested,
                  onComicChapterRequested: onComicChapterRequested,
                  onAudioChapterRequested: onAudioChapterRequested,
                  onVideoEpisodeRequested: onVideoEpisodeRequested,
                  onAddToShelf: null,
                  onRemoveFromShelf: null,
                  shelfState: shelfState,
                  onShelfAction: onShelfAction,
                  onStartReading: onStartReading,
                  onExternalUrlRequested: onExternalUrlRequested,
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
