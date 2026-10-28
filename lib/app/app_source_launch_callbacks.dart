/// App owned callback wiring for launching source backed reader and player sessions.
///
/// The app layer owns navigation and Runtime resources; presentation features
/// receive only their typed launch callbacks. Library item identity is kept on
/// persisted media callbacks and cover bytes stay attached to reader launches.
library;

import 'package:flutter/material.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/network_proxy/application/flutter_network_proxy_manager.dart';
import 'package:mg_read/features/reader/application/reader_launch_request.dart';
import 'package:mg_read/features/reader/data/transient_source_comic_reader.dart';
import 'package:mg_read/features/reader/data/transient_source_text_reader.dart';
import 'package:mg_read/features/reader/presentation/reader_entry_transition.dart';
import 'package:mg_read/features/reader/data/comic_image_transport.dart';

import 'package:mg_read/features/media/application/source_audio_player_launcher.dart';
import 'package:mg_read/features/media/application/source_video_player_launcher.dart';

/// Creates the app's standard transient launch callbacks for one route context.
final class AppSourceLaunchCallbacks {
  AppSourceLaunchCallbacks(this.context, {required this.navigatorKey});

  final BuildContext context;
  final GlobalKey<NavigatorState> navigatorKey;

  Future<void> textChapter({
    required PluginContentDetail detail,
    required PluginChaptersResult firstCatalogPage,
    required PluginChapterSummary chapter,
    required List<int>? entryCoverBytes,
  }) => _openTransientSourceTextReader(
    context,
    navigatorKey: navigatorKey,
    detail: detail,
    firstCatalogPage: firstCatalogPage,
    chapter: chapter,
    entryCoverBytes: entryCoverBytes,
  );

  Future<void> comicChapter({
    required PluginContentDetail detail,
    required PluginChaptersResult firstCatalogPage,
    required PluginChapterSummary chapter,
    required List<int>? entryCoverBytes,
  }) => _openTransientSourceComicReader(
    context,
    navigatorKey: navigatorKey,
    detail: detail,
    firstCatalogPage: firstCatalogPage,
    chapter: chapter,
    entryCoverBytes: entryCoverBytes,
  );

  Future<void> audioChapter({
    required PluginContentDetail detail,
    required PluginChaptersResult firstCatalogPage,
    required PluginChapterSummary chapter,
    required String pluginVersion,
    String? libraryItemId,
  }) {
    if (!context.mounted) return Future<void>.value();
    final navigator = navigatorKey.currentState;
    if (navigator == null) return Future<void>.error(StateError('The application navigator is not ready.'));
    return openTransientSourceAudioPlayer(
      context,
      navigator: navigator,
      detail: detail,
      firstCatalogPage: firstCatalogPage,
      chapter: chapter,
      pluginVersion: pluginVersion,
      libraryItemId: libraryItemId,
    );
  }

  Future<void> videoEpisode({
    required PluginContentDetail detail,
    required PluginChaptersResult firstCatalogPage,
    required PluginChapterSummary chapter,
    String? libraryItemId,
  }) {
    if (!context.mounted) return Future<void>.value();
    final navigator = navigatorKey.currentState;
    if (navigator == null) return Future<void>.error(StateError('The application navigator is not ready.'));
    return openTransientSourceVideoPlayer(
      context,
      navigator: navigator,
      detail: detail,
      firstCatalogPage: firstCatalogPage,
      chapter: chapter,
      libraryItemId: libraryItemId,
    );
  }
}

/// Opens a route-lifetime reader session without writing source data or state.
Future<void> _openTransientSourceTextReader(
  BuildContext context, {
  required GlobalKey<NavigatorState> navigatorKey,
  required PluginContentDetail detail,
  required PluginChaptersResult firstCatalogPage,
  required PluginChapterSummary chapter,
  required List<int>? entryCoverBytes,
}) async {
  if (!context.mounted) return Future<void>.value();
  final navigator = navigatorKey.currentState;
  if (navigator == null) {
    throw StateError('The application navigator is not ready.');
  }
  final container = ProviderScope.containerOf(context);
  final gateway = container.read(sourceContentGatewayProvider);
  final session = TransientSourceTextReader(
    detail: detail,
    catalog: firstCatalogPage,
    gateway: gateway,
    entryCoverBytes: entryCoverBytes,
    chapterPreloadCount: container.read(appSettingsProvider).get(AppSettingKeys.novelPreloadChapterCount),
    loadChapterContent: (String chapterId) {
      return gateway.getContent(pluginId: detail.pluginId, id: detail.summary.id, chapterId: chapterId);
    },
  );
  await navigator.push<void>(
    MaterialPageRoute<void>(
      builder: (BuildContext routeContext) => ReaderEntryTransition(
        request: session.createLaunchRequest(initialChapterId: chapter.id, observer: _DismissReaderObserver(navigator)),
      ),
    ),
  );
}

/// Opens a route-lifetime comic reader from a discovery/detail chapter.
Future<void> _openTransientSourceComicReader(
  BuildContext context, {
  required GlobalKey<NavigatorState> navigatorKey,
  required PluginContentDetail detail,
  required PluginChaptersResult firstCatalogPage,
  required PluginChapterSummary chapter,
  required List<int>? entryCoverBytes,
}) async {
  if (!context.mounted) return Future<void>.value();
  final NavigatorState? navigator = navigatorKey.currentState;
  if (navigator == null) throw StateError('The application navigator is not ready.');
  final container = ProviderScope.containerOf(context);
  final gateway = container.read(sourceContentGatewayProvider);
  final request = ComicReaderLaunchRequest(
    bookId: detail.summary.id,
    entryCoverBytes: entryCoverBytes,
    chapterPreloadCount: container.read(appSettingsProvider).get(AppSettingKeys.novelPreloadChapterCount),
    dataSource: TransientSourceComicReaderDataSource(
      detail: detail,
      catalog: firstCatalogPage,
      gateway: gateway,
      httpClientFactory: createProxyAwareComicHttpClientFactory(container.read(configuredFlutterNetworkProxyManagerProvider)),
    ),
    stateStore: TransientComicReaderStateStore(),
    observer: _DismissComicReaderObserver(navigator),
  );
  await navigator.push<void>(MaterialPageRoute<void>(builder: (_) => ReaderEntryTransition(request: request)));
}

final class _DismissReaderObserver extends ReaderObserver {
  const _DismissReaderObserver(this._navigator);

  final NavigatorState _navigator;

  @override
  Future<void> onExitRequested(ReaderProgress? progress) async {
    // Reader exits are funneled to the host through this callback, including
    // predictive-back completions. Guard pop to avoid double-navigation if the
    // reader route is already popped elsewhere.
    if (_navigator.mounted && _navigator.canPop()) _navigator.pop();
  }
}

final class _DismissComicReaderObserver extends ComicReaderObserver {
  const _DismissComicReaderObserver(this._navigator);

  final NavigatorState _navigator;

  @override
  Future<void> onExitRequested(ComicReaderProgress? progress) async {
    if (_navigator.mounted && _navigator.canPop()) _navigator.pop();
  }
}
