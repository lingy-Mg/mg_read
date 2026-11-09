/// Compact shell for non-TV settings and playback information only.
/// Keeps a fixed small header above scrollable content, preserves text scaling
/// and touch targets, and leaves the shared episode/TV modal geometry unchanged.
library;

// Internal presentation, not exported from the package.
// ignore_for_file: public_member_api_docs

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'video_player_visuals.dart';

class VideoPlayerCompactPanel extends StatelessWidget {
  const VideoPlayerCompactPanel({
    required this.title,
    required this.closeKey,
    required this.child,
    super.key,
  });

  final String title;
  final Key closeKey;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final pointer = videoPlayerUsesPointerControls(context);
    return Container(
      constraints: BoxConstraints(
        maxHeight: math.min(560, MediaQuery.sizeOf(context).height * .82),
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF181818),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0x18FFFFFF)),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!pointer)
                Center(
                  child: Container(
                    width: 26,
                    height: 2,
                    margin: const EdgeInsets.only(top: 8),
                    decoration: BoxDecoration(
                      color: Colors.white30,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(
                          color: videoPlayerForeground,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          letterSpacing: .1,
                        ),
                      ),
                    ),
                    IconButton(
                      key: closeKey,
                      tooltip: '关闭$title',
                      onPressed: () => Navigator.pop(context),
                      style: IconButton.styleFrom(
                        foregroundColor: videoPlayerSecondary,
                        minimumSize: Size.square(pointer ? 32 : 44),
                        tapTargetSize: pointer
                            ? MaterialTapTargetSize.shrinkWrap
                            : MaterialTapTargetSize.padded,
                        padding: const EdgeInsets.all(6),
                      ),
                      icon: const Icon(Icons.close_rounded, size: 17),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: Color(0x14FFFFFF)),
              Flexible(child: child),
            ],
          ),
        ),
      ),
    );
  }
}
