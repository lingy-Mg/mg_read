/// Runtime validation tests for immutable grouped video models.
///
/// Responsibilities:
/// - Reject ambiguous group and in-group episode identifiers in release mode.
/// - Preserve the allowed reuse of episode identifiers across different groups.
///
/// Notes:
/// - These tests do not initialize Flutter bindings or native media libraries.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read_video_player/mg_read_video_player.dart';

void main() {
  final episode = VideoEpisode(
    id: 'episode-1',
    title: '第 1 集',
    uri: 'https://example.test/1.mp4',
  );

  test('rejects duplicate group identifiers', () {
    expect(
      () => VideoContent(
        id: 'show',
        title: '节目',
        groups: <VideoEpisodeGroup>[
          VideoEpisodeGroup(
            id: 'route-a',
            title: '线路 A',
            episodes: <VideoEpisode>[episode],
          ),
          VideoEpisodeGroup(
            id: 'route-a',
            title: '线路 A 备用',
            episodes: const <VideoEpisode>[],
          ),
        ],
      ),
      throwsArgumentError,
    );
  });

  test('rejects duplicate episode identifiers inside one group', () {
    expect(
      () => VideoEpisodeGroup(
        id: 'season-1',
        title: '第一季',
        episodes: <VideoEpisode>[
          episode,
          VideoEpisode(
            id: 'episode-1',
            title: '重复集',
            uri: 'https://example.test/duplicate.mp4',
          ),
        ],
      ),
      throwsArgumentError,
    );
  });

  test('allows the same episode identifier in different groups', () {
    final content = VideoContent(
      id: 'show',
      title: '节目',
      groups: <VideoEpisodeGroup>[
        VideoEpisodeGroup(
          id: 'route-a',
          title: '线路 A',
          episodes: <VideoEpisode>[episode],
        ),
        VideoEpisodeGroup(
          id: 'route-b',
          title: '线路 B',
          episodes: <VideoEpisode>[
            VideoEpisode(
              id: 'episode-1',
              title: '第 1 集',
              uri: 'https://backup.example.test/1.mp4',
            ),
          ],
        ),
      ],
    );

    expect(content.groups[0].episodes.single.id, 'episode-1');
    expect(content.groups[1].episodes.single.id, 'episode-1');
  });
}
