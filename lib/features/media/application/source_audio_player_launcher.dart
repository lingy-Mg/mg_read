/// Source-audio launcher for the app-global playback host.
///
/// Responsibilities:
/// - Hand one selected source chapter to the process-scoped coordinator.
/// - Keep navigation free to return while the root host retains playback.
///
/// Notes:
/// - The coordinator replaces an older audio session before opening a new one.
/// - Runtime media resources remain memory-only inside the active request.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/features/media/application/source_audio_playback_coordinator.dart';

/// Opens an audio chapter in the app-root player and completes when it stops.
Future<void> openTransientSourceAudioPlayer(
  BuildContext context, {
  required NavigatorState navigator,
  required PluginContentDetail detail,
  required PluginChaptersResult firstCatalogPage,
  required PluginChapterSummary chapter,
  String? libraryItemId,
}) {
  if (!navigator.mounted) return Future<void>.value();
  final container = ProviderScope.containerOf(context, listen: false);
  return container
      .read(sourceAudioPlaybackCoordinatorProvider.notifier)
      .open(SourceAudioPlaybackRequest(detail: detail, firstCatalogPage: firstCatalogPage, chapter: chapter, libraryItemId: libraryItemId));
}
