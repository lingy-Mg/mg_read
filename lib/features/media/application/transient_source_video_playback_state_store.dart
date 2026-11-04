/// Video progress for a discovery or persisted-shelf source playback session.
///
/// The independent video player owns the session. This adapter optionally
/// persists stable group/episode identities and playback position for every
/// source video; shelf progress remains an additional projection when present.
library;

import 'dart:async';

import 'package:mg_read_video_player/mg_read_video_player.dart';
import 'package:mg_read/core/content_library/content_library.dart';

/// Keeps one transient source-video selection and its current position.
final class TransientSourceVideoPlaybackStateStore implements VideoPlaybackStateStore {
  TransientSourceVideoPlaybackStateStore({
    required this.contentId,
    required this.initialGroupId,
    required this.initialEpisodeId,
    this.library,
    Future<ContentLibrary?>? libraryFuture,
    this.libraryItemId,
    this.initialPosition,
    this.pluginId,
    this.pluginVersion,
    this.title,
    this.originDeviceId,
    this.originDeviceIdFuture,
    this.playbackSessionId,
    this.controllerDeviceId,
    this.privateContent = false,
    this.initiallyActive = true,
  }) : _active = initiallyActive,
       assert(library == null || libraryFuture == null),
       libraryFuture = libraryFuture ?? Future<ContentLibrary?>.value(library) {
    if (initialPosition != null) {
      _progress = VideoPlaybackProgress(
        contentId: contentId,
        groupId: initialGroupId,
        episodeId: initialEpisodeId,
        position: initialPosition!,
        duration: Duration.zero,
      );
    }
  }

  final String contentId;
  final String initialGroupId;
  final String initialEpisodeId;
  final ContentLibrary? library;
  final Future<ContentLibrary?> libraryFuture;
  final LibraryItemId? libraryItemId;

  /// Explicit remote position; when provided it bypasses local resume data.
  final Duration? initialPosition;

  /// Metadata used by the durable source-video history checkpoint.
  final String? pluginId, pluginVersion, title, originDeviceId, playbackSessionId, controllerDeviceId;
  final Future<String>? originDeviceIdFuture;
  final bool privateContent;
  final bool initiallyActive;
  bool _active;
  VideoPlaybackProgress? _bufferedProgress;
  VideoPlaybackProgress? _progress;
  Future<void> _saveTail = Future<void>.value();
  Future<VideoHistoryEntry?>? _historyEntryFuture;
  int _historyRevision = 0;
  int? _sessionLocalGeneration;
  Future<int>? _sessionLocalGenerationFuture;
  int _sequence = 0;
  bool _saveFailure = false;
  bool _historyConflict = false;

  /// Whether the most recent shelf or history persistence attempt failed.
  bool get saveFailure => _saveFailure;

  @override
  Future<VideoPlaybackProgress?> load(String requestedContentId) async {
    if (requestedContentId != contentId) return null;
    if (_active) await prepareActivation();
    final existing = _progress;
    if (initialPosition != null) return existing;
    if (existing != null) return existing;
    final library = await libraryFuture;
    final itemId = libraryItemId;
    if (library != null && itemId != null) {
      final stored = await library.loadProgress(itemId);
      final durable = stored is LibraryVideoPlaybackProgress ? stored : null;
      if (durable != null) {
        return _progress = VideoPlaybackProgress(
          contentId: contentId,
          groupId: durable.groupId,
          episodeId: durable.episodeId,
          position: durable.position,
          duration: durable.duration,
        );
      }
    }
    final history = await _loadHistory(library);
    if (history != null) {
      final checkpoint = history.checkpoint;
      return _progress = VideoPlaybackProgress(
        contentId: contentId,
        groupId: checkpoint.groupId,
        episodeId: checkpoint.episodeId,
        position: checkpoint.position,
        duration: checkpoint.duration,
      );
    }
    if (existing != null) return existing;
    return _progress = VideoPlaybackProgress(
      contentId: contentId,
      groupId: initialGroupId,
      episodeId: initialEpisodeId,
      position: Duration.zero,
      duration: Duration.zero,
    );
  }

  @override
  Future<void> save(VideoPlaybackProgress progress) async {
    if (progress.contentId != contentId) return;
    _progress = progress;
    if (!_active) {
      _bufferedProgress = progress;
      return;
    }
    final operation = _saveTail.then<void>((_) => _persist(progress));
    _saveTail = operation.catchError((Object _) {});
    return operation;
  }

  /// Enables history writes only after the prepared route is visibly active.
  Future<void> activate() async {
    if (_active) return;
    await prepareActivation();
    _active = true;
    final progress = _bufferedProgress;
    _bufferedProgress = null;
    if (progress != null) unawaited(save(progress).catchError((Object _) {}));
  }

  /// Reserve the session's ordering before it becomes active, including when
  /// its first progress save is delayed. This never writes a watched checkpoint.
  Future<void> prepareActivation() async {
    if (!_hasHistoryMetadata) return;
    try {
      final library = await libraryFuture;
      final device = originDeviceId ?? await originDeviceIdFuture;
      if (library != null && device != null) await _sessionGeneration(library, device);
    } on Object {
      _saveFailure = true;
    }
  }

  Future<void> _persist(VideoPlaybackProgress progress) async {
    Object? failure;
    ContentLibrary? library;
    try {
      library = await libraryFuture;
    } on Object {
      _saveFailure = true;
      throw StateError('video_progress_save_failed');
    }
    String? localDeviceId;
    try {
      if (_hasHistoryMetadata) {
        localDeviceId = originDeviceId ?? await originDeviceIdFuture;
      }
    } on Object catch (error) {
      failure = error;
    }
    if (library != null && _hasHistoryMetadata && localDeviceId != null) {
      if (_historyConflict) {
        _saveFailure = true;
        throw StateError('video_progress_save_failed');
      }
      try {
        final previous = await _loadHistory(library);
        final expectedRevision = _historyRevision > (previous?.revision ?? 0) ? _historyRevision : previous?.revision ?? 0;
        final localGeneration = await _sessionGeneration(library, localDeviceId);
        final latest = await library.readVideoHistory(videoHistorySourceKey(pluginId!, contentId));
        if (latest != null && latest.checkpoint.originDeviceId == localDeviceId && latest.checkpoint.localGeneration > localGeneration) {
          _historyConflict = true;
          failure ??= StateError('video_history_conflict');
          _saveFailure = true;
          throw _VideoHistorySessionConflict();
        }
        final updated = DateTime.now().toUtc();
        final result = await library.saveVideoHistory(
          VideoHistoryCheckpoint(
            pluginId: pluginId!,
            contentId: contentId,
            pluginVersion: pluginVersion!,
            title: title!,
            groupId: progress.groupId,
            episodeId: progress.episodeId,
            position: progress.position,
            duration: progress.duration,
            originDeviceId: localDeviceId,
            playbackSessionId: playbackSessionId!,
            controllerDeviceId: controllerDeviceId,
            sequence: ++_sequence,
            localGeneration: localGeneration,
            updatedAtUtc: updated,
          ),
          expectedLocalRevision: expectedRevision,
        );
        if (result.status == VideoHistorySaveStatus.conflict) {
          _historyConflict = true;
          failure ??= StateError('video_history_conflict');
        } else {
          _historyRevision = result.revision;
        }
      } on Object catch (error) {
        if (error is! _VideoHistorySessionConflict) failure ??= error;
      }
    }
    final itemId = libraryItemId;
    if (library != null && itemId != null && !_historyConflict) {
      try {
        await library.saveProgress(
          LibraryVideoPlaybackProgress(
            itemId: itemId,
            groupId: progress.groupId,
            episodeId: progress.episodeId,
            position: progress.position,
            duration: progress.duration,
            updatedAtUtc: DateTime.now().toUtc(),
          ),
        );
      } on Object catch (error) {
        failure ??= error;
      }
    }
    _saveFailure = failure != null;
    if (failure != null) throw StateError('video_progress_save_failed');
  }

  bool get _hasHistoryMetadata =>
      !privateContent && pluginId != null && pluginVersion != null && title != null && playbackSessionId != null;

  Future<int> _sessionGeneration(ContentLibrary library, String deviceId) {
    final existing = _sessionLocalGeneration;
    if (existing != null) return Future<int>.value(existing);
    return _sessionLocalGenerationFuture ??= library.allocateVideoHistoryGeneration(deviceId).then((generation) {
      _sessionLocalGeneration = generation;
      return generation;
    });
  }

  Future<VideoHistoryEntry?> _loadHistory(ContentLibrary? library) {
    if (library == null || !_hasHistoryMetadata) return Future.value(null);
    return _historyEntryFuture ??= library.readVideoHistory(videoHistorySourceKey(pluginId!, contentId)).then((entry) {
      _historyRevision = entry?.revision ?? 0;
      if (entry?.checkpoint.playbackSessionId == playbackSessionId) {
        _sequence = entry!.checkpoint.sequence;
      }
      return entry;
    });
  }
}

final class _VideoHistorySessionConflict implements Exception {}
