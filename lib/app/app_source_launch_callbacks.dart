/// App owned callback wiring for launching source backed reader and player sessions.
///
/// The app layer owns navigation and Runtime resources; presentation features
/// receive only their typed launch callbacks. Library item identity is kept on
/// persisted media callbacks and cover bytes stay attached to reader launches.
library;

import 'package:flutter/material.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'app_navigation_activity.dart';

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
import 'package:mg_read/features/tv_companion/application/companion_controller.dart';
import 'package:mg_read/features/tv_companion/domain/companion_models.dart';
import 'package:mg_read/features/tv_companion/domain/companion_command.dart';
import 'package:mg_read/features/tv_companion/presentation/companion_messages.dart';

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
  }) async {
    if (!context.mounted) return Future<void>.value();
    final navigator = navigatorKey.currentState;
    if (navigator == null) return Future<void>.error(StateError('The application navigator is not ready.'));
    final container = ProviderScope.containerOf(context, listen: false);
    final service = container.read(companionControllerProvider);
    final tvMode = container.read(appSettingsProvider).get(AppSettingKeys.tvMode);
    if (!tvMode && service.connectionStatus == CompanionConnectionStatus.connected) {
      final tv = await showModalBottomSheet<bool>(
        context: context,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.tv),
                title: Text('在 ${service.selectedEndpoint?.label ?? 'TV'} 播放'),
                subtitle: const Text('TV 独立解析来源，准备失败会保留当前播放'),
                onTap: () => Navigator.pop(context, true),
              ),
              ListTile(leading: const Icon(Icons.phone_android), title: const Text('在手机播放'), onTap: () => Navigator.pop(context, false)),
            ],
          ),
        ),
      );
      if (tv == null || !context.mounted) return;
      if (tv) {
        var groups = firstCatalogPage.groups.where((group) => group.episodes.any((episode) => identical(episode, chapter))).toList();
        if (groups.isEmpty) {
          groups = firstCatalogPage.groups.where((group) => group.episodes.any((episode) => episode.id == chapter.id)).toList();
        }
        PluginMediaGroup? group;
        if (groups.length > 1) {
          group = await showDialog<PluginMediaGroup>(
            context: context,
            builder: (context) => SimpleDialog(
              title: const Text('选择 TV 播放分组'),
              children: [
                for (final candidate in groups)
                  SimpleDialogOption(onPressed: () => Navigator.pop(context, candidate), child: Text(candidate.title)),
              ],
            ),
          );
          if (group == null) return;
        } else {
          group = groups.firstOrNull;
        }
        try {
          final source = (await container.read(sourceContentGatewayProvider).listSources())
              .where((source) => source.id == detail.pluginId)
              .firstOrNull;
          final result = await service.handoff(
            CompanionContentRef(
              pluginId: detail.pluginId,
              pluginVersion: source?.pluginVersion ?? 'unknown',
              contentId: detail.summary.id,
              title: detail.summary.title,
              groupId: group?.id ?? 'default',
              episodeId: chapter.id,
              useTvProgress: true,
            ),
          );
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(result.phase == CompanionCommandPhase.started ? 'TV 已实际起播，点击“连接 TV”查看遥控。' : companionErrorText(result.code)),
              ),
            );
          }
        } on Object catch (error) {
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(companionErrorText(error is CompanionFailure ? error.code : 'operation_failed'))));
          }
        }
        return;
      }
    }
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
      settings: const RouteSettings(name: appContentSessionRouteName),
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
  await navigator.push<void>(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: appContentSessionRouteName),
      builder: (_) => ReaderEntryTransition(request: request),
    ),
  );
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
