/// Delayed buffering feedback that avoids flashing for tiny network stalls.
library;

// Package-private UI helper.
// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:flutter/material.dart';

import 'video_player_visuals.dart';

final class VideoPlayerBufferingIndicator extends StatefulWidget {
  const VideoPlayerBufferingIndicator({required this.buffering, super.key});

  final bool buffering;

  @override
  State<VideoPlayerBufferingIndicator> createState() =>
      _VideoPlayerBufferingIndicatorState();
}

final class _VideoPlayerBufferingIndicatorState
    extends State<VideoPlayerBufferingIndicator> {
  Timer? _timer;
  Timer? _detailTimer;
  bool _visible = false;
  bool _showDetail = false;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant VideoPlayerBufferingIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.buffering != widget.buffering) _sync();
  }

  void _sync() {
    _timer?.cancel();
    _detailTimer?.cancel();
    if (!widget.buffering) {
      _visible = false;
      _showDetail = false;
      return;
    }
    _timer = Timer(const Duration(milliseconds: 350), () {
      if (!mounted || !widget.buffering) return;
      setState(() => _visible = true);
      _detailTimer = Timer(const Duration(milliseconds: 2500), () {
        if (mounted && widget.buffering) setState(() => _showDetail = true);
      });
    });
  }

  @override
  Widget build(BuildContext context) => !_visible
      ? const SizedBox.shrink()
      : IgnorePointer(
          child: Center(
            key: const Key('video-player-buffering'),
            child: VideoPlayerGlassPanel(
              borderRadius: BorderRadius.circular(8),
              padding: const EdgeInsets.all(10),
              showShadow: false,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: videoPlayerAccent,
                    ),
                  ),
                  if (_showDetail) ...<Widget>[
                    const SizedBox(width: 9),
                    const Text(
                      '网络缓冲中',
                      style: TextStyle(
                        color: videoPlayerForeground,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );

  @override
  void dispose() {
    _timer?.cancel();
    _detailTimer?.cancel();
    super.dispose();
  }
}
