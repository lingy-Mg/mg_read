/// Best-effort terminal cleanup for an unmounted video session.
///
/// Responsibilities:
/// - Serialize the final progress write behind every earlier queued save.
/// - Start backend cleanup immediately, independently of slow persistence.
///
/// Notes:
/// - Errors cannot be surfaced into the disposed widget tree and are isolated.
library;

import 'package:flutter/widgets.dart';

import '../api/contracts.dart';
import '../api/models.dart';

/// Whether a platform lifecycle transition requires an immediate pause.
bool pausesVideoForLifecycle(AppLifecycleState state) =>
    state == AppLifecycleState.inactive ||
    state == AppLifecycleState.paused ||
    state == AppLifecycleState.hidden ||
    state == AppLifecycleState.detached;

/// Completes persistence and backend cleanup after the view has detached.
Future<void> shutdownVideoSession({
  required VideoPlaybackBackend backend,
  required VideoPlaybackStateStore store,
  required Future<void> saveTail,
  required VideoPlaybackProgress? progress,
}) async {
  final cleanup = _cleanupBackend(backend);
  await _persistFinalProgress(
    store: store,
    saveTail: saveTail,
    progress: progress,
  );
  await cleanup;
}

Future<void> _persistFinalProgress({
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
}

Future<void> _cleanupBackend(VideoPlaybackBackend backend) async {
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
