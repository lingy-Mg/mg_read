/// Route-lifetime audio progress for a discovery source playback session.
///
/// The independent audio player owns the session. This adapter supplies its
/// initial source chapter and retains progress only while the player route is
/// alive; signed media URLs and request headers are never persisted here.
library;

import 'package:mg_read_audio_player/mg_read_audio_player.dart';

/// Keeps one transient source-audio selection and its current position.
final class TransientSourceAudioPlaybackStateStore implements AudioPlaybackStateStore {
  TransientSourceAudioPlaybackStateStore({required this.collectionId, required this.initialTrackId});

  final String collectionId;
  final String initialTrackId;
  AudioPlaybackProgress? _progress;

  @override
  Future<AudioPlaybackProgress?> loadProgress(String requestedCollectionId) async {
    if (requestedCollectionId != collectionId) return null;
    return _progress ??
        AudioPlaybackProgress(
          collectionId: collectionId,
          trackId: initialTrackId,
          position: Duration.zero,
          updatedAt: DateTime.now().toUtc(),
        );
  }

  @override
  Future<void> saveProgress(AudioPlaybackProgress progress) async {
    if (progress.collectionId == collectionId) _progress = progress;
  }
}
