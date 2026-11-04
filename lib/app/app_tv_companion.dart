/// Composition-only navigation adapters for phone-assisted TV. All navigation
/// remains inside MgRead. Settings/private/local-content routes reject remote keys.
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mg_read_video_player/mg_read_video_player.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/media/application/source_video_player_launcher.dart';
import 'package:mg_read/features/tv_companion/application/companion_controller.dart';
import 'package:mg_read/features/tv_companion/application/companion_media_host.dart';
import 'package:mg_read/features/tv_companion/application/companion_text_input.dart';
import 'package:mg_read/features/tv_companion/domain/companion_models.dart';
import 'app_router.dart';

Future<void> openCompanionDeviceSync(Ref ref) async {
  final context = appRootNavigatorKey.currentContext;
  if (context == null) throw const CompanionFailure('navigation_unavailable');
  unawaited(const ProfileSettingPlaceholderRoute(settingId: 'data-backup').push<void>(context));
}

Future<void> resumeCompanionHistoryLocally(Ref ref, VideoHistoryCheckpoint checkpoint) async {
  final navigator = appRootNavigatorKey.currentState;
  if (navigator == null) throw const CompanionFailure('media_host_unavailable');
  final gateway = ref.read(sourceContentGatewayProvider);
  final sources = await gateway.listSources();
  if (!sources.any((source) => source.id == checkpoint.pluginId && source.contentKinds.contains(PluginContentKind.video))) {
    throw const CompanionFailure('phone_source_unavailable');
  }
  final detail = await gateway.getDetail(pluginId: checkpoint.pluginId, id: checkpoint.contentId);
  var catalog = await gateway.getChapters(pluginId: checkpoint.pluginId, id: checkpoint.contentId);
  var groups = catalog.groups;
  if (groups.isEmpty) groups = [PluginMediaGroup(id: 'default', title: '默认分组', order: 0, episodes: catalog.items)];
  var group = groups.where((group) => group.id == checkpoint.groupId).firstOrNull;
  if (group?.deferred == true && gateway is SourceChapterGroupGateway) {
    final result = await (gateway as SourceChapterGroupGateway).getChapterGroup(
      pluginId: checkpoint.pluginId,
      id: checkpoint.contentId,
      groupId: checkpoint.groupId,
    );
    group = result.groups.where((group) => group.id == checkpoint.groupId && !group.deferred).firstOrNull;
    if (group != null) {
      groups = [
        for (final previous in groups)
          if (previous.id == group.id) group else previous,
      ];
      catalog = PluginChaptersResult(
        pluginId: catalog.pluginId,
        sourceName: catalog.sourceName,
        groups: groups,
        items: groups.expand((group) => group.episodes).toList(),
      );
    }
  }
  final chapter = group?.episodes.where((episode) => episode.id == checkpoint.episodeId && episode.isLocked != true).firstOrNull;
  if (chapter == null) throw const CompanionFailure('episode_unavailable');
  if (!navigator.mounted) return;
  await openTransientSourceVideoPlayer(
    navigator.context,
    navigator: navigator,
    detail: detail,
    firstCatalogPage: catalog,
    chapter: chapter,
    initialGroupId: checkpoint.groupId,
    initialPosition: checkpoint.position,
  );
}

Future<void> openCompanionSearch(Ref ref) async {
  if (ref.read(companionNavigationGuardProvider).protected) throw const CompanionFailure('navigation_unavailable');
  if (ref.read(companionTextInputProvider).attached) return;
  final navigator = appRootNavigatorKey.currentState;
  if (navigator == null) throw const CompanionFailure('search_unavailable');
  unawaited(const SearchRoute().push<void>(navigator.context));
  await WidgetsBinding.instance.endOfFrame;
  await WidgetsBinding.instance.endOfFrame;
  if (!ref.read(companionTextInputProvider).attached) throw const CompanionFailure('search_unavailable');
}

Future<void> navigateCompanion(Ref ref, String key) async {
  if (ref.read(companionNavigationGuardProvider).protected) throw const CompanionFailure('navigation_unavailable');
  final media = ref.read(companionMediaHostProvider).active;
  if (media != null && !media.privateContent && media.route?.isCurrent == true) {
    await media.controller.handleRemoteKey(VideoRemoteKey.values.byName(key));
    return;
  }
  final router = ref.read(appRouterProvider);
  final path = router.routerDelegate.currentConfiguration.uri.path;
  if (path.startsWith('/profile') || path.startsWith('/private') || path.startsWith('/reader') || path.startsWith('/local-')) {
    throw const CompanionFailure('navigation_unavailable');
  }
  final focus = FocusManager.instance.primaryFocus;
  if (key == 'back') {
    await popApplicationRoute();
    return;
  }
  if (focus == null || focus.context == null) throw const CompanionFailure('navigation_unavailable');
  if (key == 'confirm') {
    Actions.maybeInvoke(focus.context!, const ActivateIntent());
    return;
  }
  final direction = switch (key) {
    'up' => TraversalDirection.up,
    'down' => TraversalDirection.down,
    'left' => TraversalDirection.left,
    'right' => TraversalDirection.right,
    _ => throw const CompanionFailure('invalid_key'),
  };
  focus.focusInDirection(direction);
}
