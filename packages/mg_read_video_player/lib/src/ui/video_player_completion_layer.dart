/// Compact end-of-episode actions shown when automatic continuation is absent.
library;

// Package-private UI helper.
// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';

import '../api/models.dart';
import 'video_player_visuals.dart';

final class VideoPlayerCompletionLayer extends StatelessWidget {
  const VideoPlayerCompletionLayer({
    required this.snapshot,
    required this.onReplay,
    required this.onNextEpisode,
    super.key,
  });

  final VideoPlayerSnapshot snapshot;
  final VoidCallback onReplay;
  final VoidCallback onNextEpisode;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0x52000000),
    child: Center(
      child: VideoPlayerGlassPanel(
        key: const Key('video-player-completed'),
        borderRadius: BorderRadius.circular(10),
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
        showShadow: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text(
              '本集播放完毕',
              style: TextStyle(
                color: videoPlayerForeground,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                OutlinedButton.icon(
                  key: const Key('video-player-replay'),
                  onPressed: onReplay,
                  icon: const Icon(Icons.replay_rounded, size: 19),
                  label: const Text('重新播放'),
                ),
                if (snapshot.hasNextEpisode) ...<Widget>[
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    key: const Key('video-player-completed-next'),
                    onPressed: onNextEpisode,
                    icon: const Icon(Icons.skip_next_rounded, size: 20),
                    label: const Text('下一集'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
