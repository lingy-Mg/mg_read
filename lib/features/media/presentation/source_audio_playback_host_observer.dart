part of 'source_audio_playback_host.dart';

/// Bridges package failures to the app's bounded diagnostic registry.
final class _SourceAudioSessionObserver extends AudioPlayerObserver {
  const _SourceAudioSessionObserver({
    required this.onPresented,
    required this.exitRequested,
    required this.sessionEnded,
    required this.diagnostics,
  });

  final VoidCallback onPresented;
  final Future<void> Function() exitRequested;
  final VoidCallback sessionEnded;
  final DiagnosticsManager diagnostics;

  @override
  FutureOr<void> onSessionStarted(String collectionId) {
    onPresented();
  }

  @override
  void onFailure(AudioPlayerFailure failure) {
    onPresented();
    if (diagnostics.isClosed) return;
    try {
      diagnostics.emit(
        AppDiagnosticEvents.audioPlaybackFailure,
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
          'errorCode': DiagnosticValue.string(failure.code),
          'errorLocation': DiagnosticValue.string(failure.location),
          if (failure.debugDetail case final detail?) 'errorText': DiagnosticValue.string(detail),
        }),
      );
    } on Object {
      // Diagnostics are fail-open and never delay playback recovery.
    }
  }

  @override
  FutureOr<void> onExitRequested(AudioPlaybackProgress? progress) => exitRequested();

  @override
  FutureOr<void> onSessionEnded(String collectionId, AudioPlaybackProgress? progress) {
    sessionEnded();
  }
}
