/// 数据源实际检查的视频播放级验证边界。
///
/// 职责：选择有界视频样本、解析生产 Runtime 播放资源，并通过 App 提供的播放器探针验证真实首帧与进度推进。
/// 注意：稳定报告只包含样本序号、阶段、状态和安全错误分类；URL、headers、标题和原始播放器错误不得进入报告。
library;

import 'source_verification_models.dart';

import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/features/discovery/application/source_content_gateway.dart';

/// One bounded request to the App-owned video playback surface.
final class SourceVerificationVideoPlaybackRequest {
  SourceVerificationVideoPlaybackRequest({required this.uri, required this.headers, required this.timeout});

  final Uri uri;
  final Map<String, String> headers;
  final Duration timeout;
}

/// Safe playback outcome retained by the stable source-check report.
final class SourceVerificationVideoPlaybackProbeResult {
  const SourceVerificationVideoPlaybackProbeResult({
    required this.passed,
    required this.code,
    required this.elapsed,
    required this.firstFrameReady,
    required this.playing,
    required this.buffering,
    required this.position,
    required this.duration,
    required this.bufferedPosition,
    this.errorKind,
    this.errorMessage,
  });

  final bool passed;
  final String code;
  final Duration elapsed;
  final bool firstFrameReady;
  final bool playing;
  final bool buffering;
  final Duration position;
  final Duration duration;
  final Duration bufferedPosition;
  final String? errorKind;
  final String? errorMessage;

  Map<String, Object?> toSummary() => <String, Object?>{
    'status': passed ? 'passed' : 'failed',
    'code': code,
    'elapsedMs': elapsed.inMilliseconds,
    'firstFrameReady': firstFrameReady,
    'playing': playing,
    'buffering': buffering,
    'positionMs': position.inMilliseconds,
    'durationMs': duration.inMilliseconds,
    'bufferedPositionMs': bufferedPosition.inMilliseconds,
    if (errorKind != null) 'errorKind': errorKind,
    if (errorMessage != null) 'errorMessage': errorMessage,
  };
}

/// CLI-owned bridge to a mounted production video surface.
abstract interface class SourceVerificationVideoPlaybackProbe {
  Future<SourceVerificationVideoPlaybackProbeResult> probe(SourceVerificationVideoPlaybackRequest request);
}

/// Result for every selected line/sample in one source.
final class SourceVerificationVideoPlaybackResult {
  SourceVerificationVideoPlaybackResult({required this.samples, required this.totalCandidates, required this.omittedCandidates});

  final List<Map<String, Object?>> samples;
  final int totalCandidates;
  final int omittedCandidates;

  int get passedCount => samples.where((sample) => sample['status'] == 'passed').length;
  int get failedCount => samples.length - passedCount;
  bool get passed => failedCount == 0 && omittedCandidates == 0;
  String get failureCode => omittedCandidates > 0 ? 'video_playback_samples_truncated' : 'video_playback_failed';

  Map<String, Object?> get summary => <String, Object?>{
    'candidates': totalCandidates,
    'tested': samples.length,
    'passed': passedCount,
    'failed': failedCount,
    'omitted': omittedCandidates,
    'samples': samples,
  };
}

/// Resolves and plays representative episodes without retaining media values.
final class SourceVerificationVideoPlaybackRunner {
  const SourceVerificationVideoPlaybackRunner({
    required this.gateway,
    required this.probe,
    this.sampleTimeout = const Duration(seconds: 30),
    this.maximumSamples = 8,
  }) : assert(maximumSamples > 0);

  final SourceContentGateway gateway;
  final SourceVerificationVideoPlaybackProbe probe;
  final Duration sampleTimeout;
  final int maximumSamples;

  Future<SourceVerificationVideoPlaybackResult> run({
    required String pluginId,
    required String contentId,
    required PluginChaptersResult chapters,
    required List<PluginChapterContent> resolvedContents,
    SourceVerificationCancellationToken? cancellationToken,
  }) async {
    final candidates = _selectCandidates(chapters, resolvedContents);
    final selected = candidates.take(maximumSamples).toList(growable: false);
    final resolvedById = <String, PluginChapterContent>{for (final content in resolvedContents) content.chapterId: content};
    final samples = <Map<String, Object?>>[];
    for (var index = 0; index < selected.length; index += 1) {
      cancellationToken?.throwIfCancelled();
      final candidate = selected[index];
      PluginChapterContent content;
      try {
        content =
            resolvedById[candidate.chapter.id] ??
            await gateway.getContent(pluginId: pluginId, id: contentId, chapterId: candidate.chapter.id);
      } on Object catch (error) {
        samples.add(<String, Object?>{
          'sample': index + 1,
          if (candidate.groupIndex != null) 'group': candidate.groupIndex! + 1,
          'status': 'failed',
          'phase': 'resolve',
          'code': 'video_resource_resolution_failed',
          'errorType': error.runtimeType.toString(),
        });
        continue;
      }
      cancellationToken?.throwIfCancelled();
      final media = content.media;
      if (content.contentKind != PluginContentKind.video || content.chapterId != candidate.chapter.id || media == null) {
        samples.add(<String, Object?>{
          'sample': index + 1,
          if (candidate.groupIndex != null) 'group': candidate.groupIndex! + 1,
          'status': 'failed',
          'phase': 'resolve',
          'code': 'video_episode_resource_missing',
        });
        continue;
      }
      SourceVerificationVideoPlaybackProbeResult outcome;
      try {
        outcome = await probe.probe(SourceVerificationVideoPlaybackRequest(uri: media.url, headers: media.headers, timeout: sampleTimeout));
      } on Object catch (error) {
        samples.add(<String, Object?>{
          'sample': index + 1,
          if (candidate.groupIndex != null) 'group': candidate.groupIndex! + 1,
          'status': 'failed',
          'phase': 'playback',
          'code': 'video_probe_failed',
          'errorType': error.runtimeType.toString(),
        });
        continue;
      }
      samples.add(<String, Object?>{
        'sample': index + 1,
        if (candidate.groupIndex != null) 'group': candidate.groupIndex! + 1,
        'phase': 'playback',
        ...outcome.toSummary(),
      });
    }
    return SourceVerificationVideoPlaybackResult(
      samples: List<Map<String, Object?>>.unmodifiable(samples),
      totalCandidates: candidates.length,
      omittedCandidates: candidates.length - selected.length,
    );
  }
}

List<_VideoPlaybackCandidate> _selectCandidates(PluginChaptersResult chapters, List<PluginChapterContent> resolvedContents) {
  final candidates = <_VideoPlaybackCandidate>[];
  final selectedIds = <String>{};
  for (var groupIndex = 0; groupIndex < chapters.groups.length; groupIndex += 1) {
    final available = chapters.groups[groupIndex].episodes.where((episode) => episode.isLocked != true).toList(growable: false);
    if (available.isEmpty) continue;
    final chapter = available.first;
    candidates.add(_VideoPlaybackCandidate(chapter: chapter, groupIndex: groupIndex));
    selectedIds.add(chapter.id);
  }
  final chaptersById = <String, PluginChapterSummary>{for (final chapter in chapters.items) chapter.id: chapter};
  for (final content in resolvedContents) {
    if (!selectedIds.add(content.chapterId)) continue;
    final chapter = chaptersById[content.chapterId];
    if (chapter != null && chapter.isLocked != true) {
      candidates.add(_VideoPlaybackCandidate(chapter: chapter));
    }
  }
  if (candidates.isEmpty) {
    final available = chapters.items.where((chapter) => chapter.isLocked != true).toList(growable: false);
    for (final chapter in available.take(3)) {
      candidates.add(_VideoPlaybackCandidate(chapter: chapter));
    }
  }
  return List<_VideoPlaybackCandidate>.unmodifiable(candidates);
}

final class _VideoPlaybackCandidate {
  const _VideoPlaybackCandidate({required this.chapter, this.groupIndex});

  final PluginChapterSummary chapter;
  final int? groupIndex;
}
