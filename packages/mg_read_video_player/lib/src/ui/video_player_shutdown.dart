/// Best-effort terminal cleanup for an unmounted video session.
///
/// Responsibilities:
/// - Serialize the final progress write behind every earlier queued save.
/// - Pause and dispose the backend even when persistence or pause fails.
///
/// Notes:
/// - Errors cannot be surfaced into the disposed widget tree and are isolated.
library;

import '../api/contracts.dart';
import '../api/models.dart';

/// Completes persistence and backend cleanup after the view has detached.
Future<void> shutdownVideoSession({
  required VideoPlaybackBackend backend,
  required VideoPlaybackStateStore store,
  required Future<void> saveTail,
  required VideoPlaybackProgress? progress,
}) async {
  try {
    await saveTail;
  } on Object {
    // A final save is still attempted after an older failed write.
  }
  if (progress != null) {
    try {
      await store.save(progress);
    } on Object {
      // Disposal cannot surface persistence errors into a dead widget tree.
    }
  }
  try {
    await backend.pause();
  } on Object {
    // Disposal must continue when pause is unsupported or already detached.
  }
  try {
    await backend.dispose();
  } on Object {
    // Native cleanup failures cannot be recovered after route disposal.
  }
}
