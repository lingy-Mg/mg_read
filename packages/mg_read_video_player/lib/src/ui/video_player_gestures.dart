/// Direct-manipulation gestures and compact feedback for the video surface.
///
/// Responsibilities:
/// - Map horizontal distance to bounded seek previews and commits.
/// - Adjust left-side brightness, right-side volume, double-tap playback and
///   hold-to-2x without owning playback or host platform state.
///
/// Notes:
/// - Brightness is route-scoped by the host and reset when the route closes.
/// - Long press always restores the rate that was active when the hold began.
library;

// Cross-file UI helpers are intentionally package-private despite Dart naming.
// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/models.dart';
import 'video_player_visuals.dart';

final class VideoPlayerGestureLayer extends StatefulWidget {
  const VideoPlayerGestureLayer({
    required this.snapshot,
    required this.onToggleControls,
    required this.onPlayOrPause,
    required this.onSeekPreviewChanged,
    required this.onSeekPreviewEnded,
    required this.onSeekPreviewCanceled,
    required this.onRate,
    required this.onVolume,
    required this.onReadBrightness,
    required this.onBrightness,
    required this.locked,
    required this.onInteractionStart,
    required this.onInteractionEnd,
    super.key,
  });

  final VideoPlayerSnapshot snapshot;
  final VoidCallback onToggleControls;
  final VoidCallback onPlayOrPause;
  final ValueChanged<Duration> onSeekPreviewChanged;
  final ValueChanged<Duration> onSeekPreviewEnded;
  final VoidCallback onSeekPreviewCanceled;
  final ValueChanged<double> onRate;
  final ValueChanged<double> onVolume;
  final Future<double?> Function() onReadBrightness;
  final ValueChanged<double> onBrightness;
  final bool locked;
  final VoidCallback onInteractionStart;
  final VoidCallback onInteractionEnd;

  @override
  State<VideoPlayerGestureLayer> createState() =>
      _VideoPlayerGestureLayerState();
}

final class _VideoPlayerGestureLayerState
    extends State<VideoPlayerGestureLayer> {
  Timer? _hudTimer;
  _GestureHud? _hud;
  Duration _seekBase = Duration.zero;
  Duration? _seekPreview;
  double _horizontalDistance = 0;
  bool _brightnessGesture = false;
  bool _verticalGestureActive = false;
  double _verticalDistance = 0;
  double _volumeBase = 100;
  double? _brightnessBase;
  int _brightnessReadGeneration = 0;
  bool _longPressActive = false;
  double _rateBeforeLongPress = 1;

  @override
  void didUpdateWidget(covariant VideoPlayerGestureLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.snapshot.activeEpisodeId != widget.snapshot.activeEpisodeId) {
      _seekPreview = null;
      _horizontalDistance = 0;
    }
    if (_longPressActive &&
        (!widget.snapshot.playing || (!oldWidget.locked && widget.locked))) {
      _longPressActive = false;
      widget.onRate(_rateBeforeLongPress);
      _finishHudSoon();
      widget.onInteractionEnd();
    }
  }

  void _showHud(_GestureHud hud, {bool persistent = false}) {
    _hudTimer?.cancel();
    setState(() => _hud = hud);
    if (!persistent) {
      _hudTimer = Timer(const Duration(milliseconds: 650), () {
        if (mounted) setState(() => _hud = null);
      });
    }
  }

  void _startSeek(DragStartDetails details) {
    widget.onInteractionStart();
    _hudTimer?.cancel();
    _horizontalDistance = 0;
    _seekBase = widget.snapshot.position;
    _seekPreview = _seekBase;
    _showSeekHud();
  }

  void _updateSeek(DragUpdateDetails details) {
    _horizontalDistance += details.primaryDelta ?? 0;
    final width = context.size?.width ?? 1;
    final duration = widget.snapshot.duration;
    final spanSeconds = (duration.inSeconds * .12).clamp(60, 600).toDouble();
    final deltaSeconds = (_horizontalDistance / width * spanSeconds).round();
    final target = _clampDuration(
      _seekBase + Duration(seconds: deltaSeconds),
      duration,
    );
    setState(() => _seekPreview = target);
    _showSeekHud();
  }

  void _showSeekHud() {
    final preview = _seekPreview ?? _seekBase;
    widget.onSeekPreviewChanged(preview);
  }

  void _finishSeek(DragEndDetails details) {
    final target = _seekPreview;
    if (target != null) widget.onSeekPreviewEnded(target);
    _seekPreview = null;
    widget.onInteractionEnd();
  }

  void _cancelSeek() {
    _seekPreview = null;
    widget.onSeekPreviewCanceled();
    widget.onInteractionEnd();
  }

  void _startVertical(DragStartDetails details) {
    widget.onInteractionStart();
    _hudTimer?.cancel();
    _verticalGestureActive = true;
    _verticalDistance = 0;
    _brightnessGesture =
        details.localPosition.dx < (context.size?.width ?? 0) / 2;
    if (_brightnessGesture) {
      final generation = ++_brightnessReadGeneration;
      _brightnessBase = null;
      unawaited(
        widget.onReadBrightness().then((value) {
          if (!mounted || generation != _brightnessReadGeneration) return;
          setState(() => _brightnessBase = (value ?? .5).clamp(0.05, 1));
          _applyVertical();
          if (!_verticalGestureActive) _finishHudSoon();
        }),
      );
      _showHud(
        const _GestureHud(
          icon: Icons.brightness_6_rounded,
          title: '亮度',
          detail: '读取中',
        ),
        persistent: true,
      );
      return;
    }
    _volumeBase = widget.snapshot.volume;
    _applyVertical();
  }

  void _updateVertical(DragUpdateDetails details) {
    _verticalDistance += details.primaryDelta ?? 0;
    _applyVertical();
  }

  void _applyVertical() {
    final height = context.size?.height ?? 1;
    final normalizedDelta = -_verticalDistance / height;
    if (_brightnessGesture) {
      final base = _brightnessBase;
      if (base == null) return;
      final value = (base + normalizedDelta).clamp(0.05, 1).toDouble();
      widget.onBrightness(value);
      _showHud(
        _GestureHud(
          icon: Icons.brightness_6_rounded,
          title: '亮度',
          detail: '${(value * 100).round()}%',
          progress: value,
        ),
        persistent: true,
      );
      return;
    }
    final value = (_volumeBase + normalizedDelta * 100)
        .clamp(0, 100)
        .toDouble();
    widget.onVolume(value);
    _showHud(
      _GestureHud(
        icon: value == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
        title: '音量',
        detail: '${value.round()}%',
        progress: value / 100,
      ),
      persistent: true,
    );
  }

  void _finishVertical(DragEndDetails details) {
    _verticalGestureActive = false;
    _finishHudSoon();
    widget.onInteractionEnd();
  }

  void _cancelVertical() {
    _verticalGestureActive = false;
    _brightnessReadGeneration++;
    _finishHudSoon();
    widget.onInteractionEnd();
  }

  void _togglePlayback() {
    widget.onInteractionStart();
    widget.onPlayOrPause();
    unawaited(HapticFeedback.selectionClick());
    widget.onInteractionEnd();
  }

  void _startLongPress(LongPressStartDetails details) {
    if (!widget.snapshot.playing || _longPressActive) return;
    _longPressActive = true;
    widget.onInteractionStart();
    _rateBeforeLongPress = widget.snapshot.rate;
    widget.onRate(2);
    unawaited(HapticFeedback.mediumImpact());
    _showHud(
      const _GestureHud(
        icon: Icons.fast_forward_rounded,
        title: '2.0× 快进播放',
        detail: '松开恢复原速度',
      ),
      persistent: true,
    );
  }

  void _finishLongPress() {
    if (!_longPressActive) return;
    _longPressActive = false;
    widget.onRate(_rateBeforeLongPress);
    _finishHudSoon();
    widget.onInteractionEnd();
  }

  void _finishHudSoon() {
    _hudTimer?.cancel();
    if (_hud == null) return;
    _hudTimer = Timer(const Duration(milliseconds: 650), () {
      if (mounted) setState(() => _hud = null);
    });
  }

  void _handleTap() {
    widget.onToggleControls();
    if (widget.locked) return;
    widget.onInteractionEnd();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: <Widget>[
      Semantics(
        label: '视频手势区域',
        hint: widget.locked
            ? '播放器手势已锁定，点击显示解锁按钮'
            : '双击播放暂停，长按二倍速，横滑快进快退，左侧调亮度，右侧调音量',
        child: GestureDetector(
          key: const Key('video-player-gesture-layer'),
          behavior: HitTestBehavior.opaque,
          onTap: _handleTap,
          onDoubleTap: widget.locked ? null : _togglePlayback,
          onHorizontalDragStart: widget.locked ? null : _startSeek,
          onHorizontalDragUpdate: widget.locked ? null : _updateSeek,
          onHorizontalDragEnd: widget.locked ? null : _finishSeek,
          onHorizontalDragCancel: widget.locked ? null : _cancelSeek,
          onVerticalDragStart: widget.locked ? null : _startVertical,
          onVerticalDragUpdate: widget.locked ? null : _updateVertical,
          onVerticalDragEnd: widget.locked ? null : _finishVertical,
          onVerticalDragCancel: widget.locked ? null : _cancelVertical,
          onLongPressStart: widget.locked ? null : _startLongPress,
          onLongPressEnd: widget.locked ? null : (_) => _finishLongPress(),
          onLongPressCancel: widget.locked ? null : _finishLongPress,
        ),
      ),
      if (_hud case final hud?)
        IgnorePointer(
          child: Center(child: _GestureHudView(hud: hud)),
        ),
    ],
  );

  @override
  void dispose() {
    _hudTimer?.cancel();
    super.dispose();
  }
}

final class _GestureHud {
  const _GestureHud({
    this.icon,
    required this.title,
    this.detail,
    this.progress,
  });

  final IconData? icon;
  final String title;
  final String? detail;
  final double? progress;
}

final class _GestureHudView extends StatelessWidget {
  const _GestureHudView({required this.hud});

  final _GestureHud hud;

  @override
  Widget build(BuildContext context) => VideoPlayerGlassPanel(
    key: const Key('video-player-gesture-hud'),
    borderRadius: BorderRadius.circular(8),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    showShadow: false,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 112, maxWidth: 220),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (hud.icon case final icon?) ...<Widget>[
                Icon(icon, size: 20, color: videoPlayerForeground),
                const SizedBox(width: 7),
              ],
              Flexible(
                child: Text(
                  hud.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: videoPlayerForeground,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (hud.detail case final detail?) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              detail,
              style: const TextStyle(color: videoPlayerSecondary, fontSize: 12),
            ),
          ],
          if (hud.progress case final progress?) ...<Widget>[
            const SizedBox(height: 7),
            LinearProgressIndicator(
              minHeight: 2,
              value: progress.clamp(0, 1),
              backgroundColor: const Color(0x32FFFFFF),
              color: videoPlayerAccent,
            ),
          ],
        ],
      ),
    ),
  );
}

Duration _clampDuration(Duration value, Duration duration) {
  if (value < Duration.zero) return Duration.zero;
  if (duration > Duration.zero && value > duration) return duration;
  return value;
}
