/// Active-audio lifecycle policy shared by the player host and system events.
///
/// Responsibilities:
/// - Keep the display awake while allowing Android to dim it after inactivity.
/// - Hold that request only while enabled, visible and actually playing.
/// - Reflect the persisted audio preference without owning player UI.
/// - Release only this audio session's screen-awake lease on pause or lock.
///
/// Notes:
/// - Manual screen-off remains authoritative; background playback is untouched.
/// - The coordinator composes this lease with readers and other host operations.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:mg_read_audio_player/mg_read_audio_player.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

import 'package:mg_read/core/settings/settings.dart';

abstract interface class SourceAudioScreenAwakePort {
  Future<void> acquire(Object holder);
  Future<void> release(Object holder);
}

final class _CoordinatedSourceAudioScreenAwakePort implements SourceAudioScreenAwakePort {
  const _CoordinatedSourceAudioScreenAwakePort();

  @override
  Future<void> acquire(Object holder) => ScreenAwakeCoordinator.instance.acquire(holder, allowScreenDimming: true);

  @override
  Future<void> release(Object holder) => ScreenAwakeCoordinator.instance.release(holder);
}

final class SourceAudioPlaybackLifecycle with WidgetsBindingObserver {
  factory SourceAudioPlaybackLifecycle({
    required AudioPlayerController controller,
    required AppSettingsManager settings,
    VoidCallback? onPreferenceChanged,
    SourceAudioScreenAwakePort screenAwakePort = const _CoordinatedSourceAudioScreenAwakePort(),
    AppLifecycleState? initialLifecycleState,
  }) => SourceAudioPlaybackLifecycle._(controller, settings, onPreferenceChanged, screenAwakePort, initialLifecycleState);

  SourceAudioPlaybackLifecycle._(
    this._controller,
    this._settings,
    this._onPreferenceChanged,
    this._screenAwakePort,
    AppLifecycleState? initialLifecycleState,
  ) : _appVisible = _isInitiallyVisible(initialLifecycleState) {
    _keepScreenOn = _settings.supports(AppSettingKeys.audioKeepScreenOn) ? _settings.get(AppSettingKeys.audioKeepScreenOn) : true;
    _controller.addListener(_syncLease);
    WidgetsBinding.instance.addObserver(this);
    _settingsChanges = _settings.changeEvents.listen(_handleSettingsChange);
    _syncLease();
  }

  final AudioPlayerController _controller;
  final AppSettingsManager _settings;
  final VoidCallback? _onPreferenceChanged;
  final SourceAudioScreenAwakePort _screenAwakePort;
  late final StreamSubscription<SettingsChangeEvent> _settingsChanges;
  final Object _holder = Object();
  late bool _keepScreenOn;
  bool _appVisible;
  bool _leaseHeld = false;
  bool _disposed = false;

  static bool _isInitiallyVisible(AppLifecycleState? explicitState) {
    final state = explicitState ?? WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  bool get keepScreenOn => _keepScreenOn;

  Future<void> setKeepScreenOn(bool enabled) {
    if (_disposed || !_settings.supports(AppSettingKeys.audioKeepScreenOn)) {
      return Future<void>.value();
    }
    return _settings.set(AppSettingKeys.audioKeepScreenOn, enabled);
  }

  void _handleSettingsChange(SettingsChangeEvent event) {
    if (!event.changedKeyIds.contains(AppSettingKeys.audioKeepScreenOn.id)) {
      return;
    }
    final enabled = event.snapshot.get(AppSettingKeys.audioKeepScreenOn);
    if (_keepScreenOn == enabled) return;
    _keepScreenOn = enabled;
    _syncLease();
    _onPreferenceChanged?.call();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final visible = state == AppLifecycleState.resumed;
    if (_appVisible == visible) return;
    _appVisible = visible;
    _syncLease();
  }

  void _syncLease() {
    if (_disposed) return;
    final shouldHold = _keepScreenOn && _appVisible && _controller.snapshot.playing;
    if (_leaseHeld == shouldHold) return;
    _leaseHeld = shouldHold;
    if (shouldHold) {
      _screenAwakePort.acquire(_holder).ignore();
    } else {
      _screenAwakePort.release(_holder).ignore();
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_syncLease);
    _settingsChanges.cancel().ignore();
    if (_leaseHeld) {
      _leaseHeld = false;
      _screenAwakePort.release(_holder).ignore();
    }
  }
}
