/// Process-scoped ownership for one source-audio playback session.
///
/// Responsibilities:
/// - Keep the active audio request alive independently of page navigation.
/// - Expose expanded/minimized presentation state to the root playback host.
/// - Pause and retire audio before another audio session or video begins.
///
/// Notes:
/// - The request may contain Runtime session resources and therefore remains
///   memory-only for exactly the lifetime of the active player.
/// - Durable progress and exit preferences stay owned by their existing host
///   stores; this coordinator persists neither media URLs nor headers.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mg_read_audio_player/mg_read_audio_player.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

/// Source inputs retained only while their global audio session is active.
final class SourceAudioPlaybackRequest {
  const SourceAudioPlaybackRequest({
    required this.detail,
    required this.firstCatalogPage,
    required this.chapter,
    required this.libraryItemId,
  });

  final PluginContentDetail detail;
  final PluginChaptersResult firstCatalogPage;
  final PluginChapterSummary chapter;
  final String? libraryItemId;
}

enum SourceAudioPresentation { inactive, expanded, minimized }

/// Immutable state consumed by the app-root audio host.
final class SourceAudioPlaybackState {
  const SourceAudioPlaybackState._({required this.presentation, this.sessionId, this.request});

  const SourceAudioPlaybackState.inactive() : this._(presentation: SourceAudioPresentation.inactive);

  const SourceAudioPlaybackState.active({
    required int sessionId,
    required SourceAudioPlaybackRequest request,
    required SourceAudioPresentation presentation,
  }) : this._(presentation: presentation, sessionId: sessionId, request: request);

  final SourceAudioPresentation presentation;
  final int? sessionId;
  final SourceAudioPlaybackRequest? request;

  bool get isActive => presentation != SourceAudioPresentation.inactive && sessionId != null && request != null;
}

final sourceAudioPlaybackCoordinatorProvider = NotifierProvider<SourceAudioPlaybackCoordinator, SourceAudioPlaybackState>(
  SourceAudioPlaybackCoordinator.new,
);

/// Optional host transport seam; production uses the package MediaKit backend.
typedef SourceAudioPlaybackBackendFactory = AudioPlaybackBackend Function();

final sourceAudioPlaybackBackendFactoryProvider = Provider<SourceAudioPlaybackBackendFactory?>((ref) => null);

/// Owns the lifetime and presentation of the one app-global audio session.
final class SourceAudioPlaybackCoordinator extends Notifier<SourceAudioPlaybackState> {
  int _nextSessionId = 0;
  AudioPlayerController? _controller;
  Completer<void>? _completion;
  bool _disposed = false;

  @override
  SourceAudioPlaybackState build() {
    ref.onDispose(() {
      _disposed = true;
      unawaited(_controller?.pause());
      _controller = null;
      _completeCurrent();
    });
    return const SourceAudioPlaybackState.inactive();
  }

  /// Replaces any existing playback and expands the new session globally.
  Future<void> open(SourceAudioPlaybackRequest request) async {
    await stop();
    if (_disposed) return;
    final completion = Completer<void>();
    _completion = completion;
    final sessionId = ++_nextSessionId;
    state = SourceAudioPlaybackState.active(sessionId: sessionId, request: request, presentation: SourceAudioPresentation.expanded);
    await completion.future;
  }

  /// Registers the controller created by the matching root-host session.
  bool attachController(int sessionId, AudioPlayerController controller) {
    if (_disposed || state.sessionId != sessionId) return false;
    _controller = controller;
    return true;
  }

  void detachController(int sessionId, AudioPlayerController controller) {
    if (state.sessionId == sessionId && identical(_controller, controller)) {
      _controller = null;
    }
  }

  void minimize(int sessionId) {
    final request = state.request;
    if (_disposed || state.sessionId != sessionId || request == null) return;
    state = SourceAudioPlaybackState.active(sessionId: sessionId, request: request, presentation: SourceAudioPresentation.minimized);
  }

  void expand() {
    final request = state.request;
    final sessionId = state.sessionId;
    if (_disposed || request == null || sessionId == null) return;
    state = SourceAudioPlaybackState.active(sessionId: sessionId, request: request, presentation: SourceAudioPresentation.expanded);
  }

  /// Pauses first so a following video cannot overlap audible output.
  Future<void> stop({int? sessionId}) async {
    final activeSessionId = state.sessionId;
    if (activeSessionId == null || (sessionId != null && activeSessionId != sessionId)) {
      return;
    }
    final controller = _controller;
    if (controller != null) await controller.pause();
    if (state.sessionId != activeSessionId) return;
    _controller = null;
    state = const SourceAudioPlaybackState.inactive();
    _completeCurrent();
  }

  /// Retires a session that ended independently inside the player package.
  void sessionEnded(int sessionId) {
    if (_disposed || state.sessionId != sessionId) return;
    _controller = null;
    state = const SourceAudioPlaybackState.inactive();
    _completeCurrent();
  }

  void _completeCurrent() {
    final completion = _completion;
    _completion = null;
    if (completion != null && !completion.isCompleted) completion.complete();
  }
}
