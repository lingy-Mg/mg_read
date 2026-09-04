/// Video progress for a discovery or persisted-shelf source playback session.
///
/// The independent video player owns the session. This adapter optionally
/// persists only stable group/episode identities and playback position for a
/// shelf item; signed resources and Runtime session data remain transient.
library;

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
  }) : assert(library == null || libraryFuture == null),
       assert((library == null && libraryFuture == null) == (libraryItemId == null)),
       libraryFuture = libraryFuture ?? Future<ContentLibrary?>.value(library);

  final String contentId;
  final String initialGroupId;
  final String initialEpisodeId;
  final ContentLibrary? library;
  final Future<ContentLibrary?> libraryFuture;
  final LibraryItemId? libraryItemId;
  VideoPlaybackProgress? _progress;

  @override
  Future<VideoPlaybackProgress?> load(String requestedContentId) async {
    if (requestedContentId != contentId) return null;
    final existing = _progress;
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
    final library = await libraryFuture;
    final itemId = libraryItemId;
    if (library == null || itemId == null) return;
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
  }
}
