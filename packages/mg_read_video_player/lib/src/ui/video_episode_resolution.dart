/// Package-private selected-episode resource resolution.
///
/// Responsibilities:
/// - Preserve metadata-only catalogs while resolving one playback resource.
/// - Normalize host failures without exposing signed URLs or raw exceptions.
///
/// Notes:
/// - The caller still owns generation checks before applying this result.
/// - Resolved titles come from the catalog, not transient resource responses.
library;

// Cross-file session helpers are intentionally package-private.
// ignore_for_file: public_member_api_docs

import '../api/contracts.dart';
import '../api/models.dart';

typedef VideoEpisodeResolution = ({
  VideoEpisode? episode,
  VideoPlayerFailure? failure,
});

Future<VideoEpisodeResolution> resolveVideoEpisode({
  required VideoDataSource dataSource,
  required String contentId,
  required VideoEpisodeGroup group,
  required VideoEpisode episode,
}) async {
  if (episode.hasPlaybackResource) return (episode: episode, failure: null);
  if (dataSource is! VideoEpisodeDataSource) {
    return (
      episode: null,
      failure: const VideoPlayerFailure(
        VideoPlayerFailureKind.data,
        '数据源没有提供所选视频的播放资源。',
        code: 'episode_resource_missing',
        location: '解析所选视频资源',
      ),
    );
  }
  try {
    final resolved = await dataSource.loadEpisode(
      contentId,
      groupId: group.id,
      episodeId: episode.id,
    );
    if (resolved.id != episode.id || !resolved.hasPlaybackResource) {
      return (
        episode: null,
        failure: const VideoPlayerFailure(
          VideoPlayerFailureKind.data,
          '数据源返回的播放资源与所选视频不匹配。',
          code: 'episode_resource_identity_mismatch',
          location: '校验所选视频资源',
        ),
      );
    }
    return (
      episode: VideoEpisode(
        id: episode.id,
        title: episode.title,
        uri: resolved.uri,
        httpHeaders: resolved.httpHeaders,
        durationHint: resolved.durationHint ?? episode.durationHint,
      ),
      failure: null,
    );
  } on VideoPlayerLoadException catch (error) {
    return (
      episode: null,
      failure: VideoPlayerFailure(
        VideoPlayerFailureKind.data,
        error.message,
        code: error.code,
        location: error.location,
      ),
    );
  } on Object {
    return (
      episode: null,
      failure: const VideoPlayerFailure(
        VideoPlayerFailureKind.data,
        '所选视频资源暂时无法获取，请稍后重试',
        code: 'episode_resource_load_failed',
        location: '解析所选视频资源',
      ),
    );
  }
}
