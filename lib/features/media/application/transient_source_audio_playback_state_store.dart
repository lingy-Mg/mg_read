/// Audio progress for a discovery or persisted-shelf source playback session.
///
/// The independent player owns the session. This adapter persists only a
/// stable source chapter identity and position for shelf items.
library;

import 'package:mg_read_audio_player/mg_read_audio_player.dart';
import 'package:mg_read/core/content_library/content_library.dart';

/// Keeps one source-audio selection and optionally commits it to the shelf.
final class TransientSourceAudioPlaybackStateStore implements AudioPlaybackStateStore {
  TransientSourceAudioPlaybackStateStore({required this.collectionId, required this.initialTrackId, this.library, this.libraryItemId})
    : assert((library == null) == (libraryItemId == null));

  final String collectionId;
  final String initialTrackId;
  final ContentLibrary? library;
  final LibraryItemId? libraryItemId;
  AudioPlaybackProgress? _progress;

  @override
  Future<AudioPlaybackProgress?> loadProgress(String requestedCollectionId) async {
    if (requestedCollectionId != collectionId) return null;
    final existing = _progress;
    if (existing != null) return existing;
    final library = this.library;
    final itemId = libraryItemId;
    if (library != null && itemId != null) {
      final stored = await library.loadProgress(itemId);
      final durable = stored is LibraryAudioPlaybackProgress ? stored : null;
      if (durable != null) {
        return _progress = AudioPlaybackProgress(
          collectionId: collectionId,
          trackId: durable.chapterId,
          position: durable.position,
          updatedAt: durable.updatedAtUtc,
        );
      }
    }
    return _progress ??= AudioPlaybackProgress(
      collectionId: collectionId,
      trackId: initialTrackId,
      position: Duration.zero,
      updatedAt: DateTime.now().toUtc(),
    );
  }

  @override
  Future<void> saveProgress(AudioPlaybackProgress progress) async {
    if (progress.collectionId != collectionId) return;
    _progress = progress;
    final library = this.library;
    final itemId = libraryItemId;
    if (library == null || itemId == null) return;
    await library.saveProgress(
      LibraryAudioPlaybackProgress(
        itemId: itemId,
        chapterId: progress.trackId,
        position: progress.position,
        updatedAtUtc: progress.updatedAt,
      ),
    );
  }
}
