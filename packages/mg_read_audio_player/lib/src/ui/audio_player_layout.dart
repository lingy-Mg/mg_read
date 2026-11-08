/// Responsive composition for the production audio player.
///
/// Owns only layout: portrait prioritizes artwork, landscape places controls
/// alongside it. Short screens and enlarged text can scroll without shrinking
/// touch targets or truncating transport controls. No session state or I/O.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'audio_player_theme.dart';

final class AudioPlayerLayout extends StatelessWidget {
  const AudioPlayerLayout({
    required this.topBar,
    required this.coverBuilder,
    required this.metadata,
    required this.progress,
    required this.transport,
    required this.shortcuts,
    this.failure,
    super.key,
  });

  final Widget topBar;
  final Widget Function(double size) coverBuilder;
  final Widget metadata;
  final Widget progress;
  final Widget transport;
  final Widget shortcuts;
  final Widget? failure;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: LayoutBuilder(
      builder: (context, viewport) {
        final wide =
            viewport.maxWidth >= 840 ||
            (viewport.maxWidth >= 620 &&
                viewport.maxWidth > viewport.maxHeight * 1.3);
        final padding = viewport.maxWidth < 360 ? 20.0 : 28.0;
        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: wide ? 1080 : AudioPlayerMetrics.pageMaxWidth,
            ),
            child: Padding(
              padding: EdgeInsets.fromLTRB(padding, 8, padding, 12),
              child: Column(
                children: <Widget>[
                  topBar,
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, body) => ScrollConfiguration(
                        behavior: ScrollConfiguration.of(
                          context,
                        ).copyWith(scrollbars: false),
                        child: SingleChildScrollView(
                          key: const Key('audio-player-scroll'),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              minHeight: body.maxHeight,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: <Widget>[
                                if (failure case final message?)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 12),
                                    child: message,
                                  ),
                                ConstrainedBox(
                                  constraints: BoxConstraints(
                                    minHeight: failure == null
                                        ? body.maxHeight
                                        : 0,
                                  ),
                                  child: wide
                                      ? _wide(body)
                                      : _portrait(body, viewport.maxHeight),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );

  Widget _portrait(BoxConstraints body, double height) {
    final short = height < 620;
    final coverSize = math.min(
      body.maxWidth,
      (height - 436).clamp(short ? 120.0 : 156.0, 360.0),
    );
    return Column(
      key: const Key('audio-portrait-layout'),
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.only(
            top: short
                ? 12
                : height < 760
                ? 16
                : 28,
            bottom: short ? 16 : 28,
          ),
          child: Center(child: coverBuilder(coverSize)),
        ),
        _controls(),
        Padding(
          padding: EdgeInsets.only(top: short ? 16 : 24, bottom: 4),
          child: shortcuts,
        ),
      ],
    );
  }

  Widget _wide(BoxConstraints body) {
    final coverSize = math.min(
      (body.maxWidth - 56) / 2,
      (body.maxHeight - 16).clamp(156.0, 400.0),
    );
    return Padding(
      key: const Key('audio-landscape-layout'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          Expanded(child: Center(child: coverBuilder(coverSize))),
          const SizedBox(width: 48),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _controls(compact: true),
                const SizedBox(height: 8),
                shortcuts,
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _controls({bool compact = false}) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      metadata,
      SizedBox(height: compact ? 4 : 18),
      progress,
      SizedBox(height: compact ? 4 : 10),
      transport,
    ],
  );
}
