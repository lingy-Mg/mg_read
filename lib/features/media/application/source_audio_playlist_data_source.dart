/// Audio-source to independent-player adapter.
///
/// Responsibilities:
/// - Expose the complete safe chapter catalog while resolving URLs on demand.
/// - Preserve proxy URLs, request headers and refresh policy as opaque data.
/// - Single-flight detail and catalog reads for the active collection.
/// - Cancel superseded Runtime resource calls and bound continuation attempts.
///
/// Notes:
/// - This is audio-only; it never creates a video group or shares player state.
/// - Locked or failed neighbouring entries never prevent a selected free track
///   from opening. Resource resolution remains part of the active session.
/// - Temporary failures stop a batch; only a structurally missing resource is
///   skipped, so recovery cannot silently jump over unheard chapters.
library;

import 'package:mg_read_audio_player/mg_read_audio_player.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/features/discovery/application/source_content_gateway.dart';

/// Converts one audio source collection into the audio player's host port.
final class SourceAudioPlaylistDataSource implements AudioPlaylistQueueDataSource, AudioPlayerCancellationDataSource {
  SourceAudioPlaylistDataSource({
    required this.gateway,
    required this.pluginId,
    this.initialTrackId,
    this.initialDetail,
    this.initialCatalog,
  });

  final SourceContentGateway gateway;
  final String pluginId;
  final String? initialTrackId;
  final PluginContentDetail? initialDetail;
  final PluginChaptersResult? initialCatalog;
  String? _cachedCollectionId;
  Future<PluginContentDetail>? _detailFuture;
  Future<PluginChaptersResult>? _catalogFuture;
  PluginInvocationCancellation? _resourceCancellation;
  int _resourceRequestId = 0;

  @override
  void cancelPendingLoads() {
    _resourceRequestId++;
    _resourceCancellation?.cancel();
    _resourceCancellation = null;
  }

  @override
  Future<AudioPlaylist> loadPlaylist(String collectionId) async {
    final detail = await _loadDetail(collectionId);
    if (detail.summary.contentKind != PluginContentKind.audio) {
      throw const AudioPlayerLoadException(code: 'audio_source_kind_invalid', location: '音频详情', message: '当前内容不是可播放音频，请返回详情页后重试。');
    }
    if (detail.summary.id != collectionId) {
      throw const AudioPlayerLoadException(code: 'audio_detail_outdated', location: '音频详情', message: '当前详情已更新，请返回详情页后重新打开。');
    }
    final catalog = await _loadCatalog(collectionId);
    final available = _availableChapters(catalog.items);
    final candidates = _selectCandidates(available);
    if (available.isEmpty || candidates.isEmpty) {
      throw const AudioPlayerLoadException(code: 'audio_catalog_no_playable_chapter', location: '音频目录', message: '目录中没有可播放的免费章节。');
    }
    final tracks = <AudioTrack>[];
    try {
      tracks.add(
        await _runResourceRequest(
          (cancellation) => _loadTrack(detail: detail, collectionId: collectionId, chapter: candidates.first, cancellation: cancellation),
        ),
      );
    } on AudioPlayerLoadException {
      rethrow;
    } on Object catch (error) {
      throw AudioPlayerLoadException(
        code: 'audio_selected_resource_unavailable',
        location: '所选章节的播放地址',
        message: '数据源未能返回可播放地址。请检查网络或稍后重试。',
        debugDetail: _sourceFailureDetail(error),
      );
    }
    return AudioPlaylist(
      collectionId: collectionId,
      title: detail.summary.title,
      creator: detail.summary.author,
      tracks: tracks,
      queueEntries: <AudioQueueEntry>[
        for (final chapter in catalog.items)
          AudioQueueEntry(
            id: chapter.id,
            title: chapter.title,
            creator: detail.summary.author,
            artwork: detail.summary.coverUrl,
            isLocked: chapter.isLocked == true,
          ),
      ],
    );
  }

  List<PluginChapterSummary> _selectCandidates(List<PluginChapterSummary> catalog) {
    final available = _availableChapters(catalog);
    if (available.isEmpty) return const <PluginChapterSummary>[];
    final requestedIndex = initialTrackId == null ? 0 : available.indexWhere((chapter) => chapter.id == initialTrackId);
    // A removed or newly locked remembered chapter must not make the shelf
    // item unusable. Resume the saved chapter when it still exists; otherwise
    // start at the first currently playable chapter.
    return <PluginChapterSummary>[available[requestedIndex < 0 ? 0 : requestedIndex]];
  }

  List<PluginChapterSummary> _availableChapters(List<PluginChapterSummary> catalog) =>
      catalog.where((chapter) => chapter.isLocked != true).toList(growable: false);

  @override
  Future<AudioTrack> loadTrackById(String collectionId, {required String trackId}) async {
    final detail = await _loadDetail(collectionId);
    final catalog = await _loadCatalog(collectionId);
    PluginChapterSummary? chapter;
    for (final item in _availableChapters(catalog.items)) {
      if (item.id == trackId) {
        chapter = item;
        break;
      }
    }
    if (detail.summary.id != collectionId || detail.summary.contentKind != PluginContentKind.audio || chapter == null) {
      throw const AudioPlayerLoadException(code: 'audio_selected_chapter_unavailable', location: '所选章节', message: '所选章节已下架、锁定或不在当前目录中。');
    }
    return _runResourceRequest(
      (cancellation) => _loadTrack(detail: detail, collectionId: collectionId, chapter: chapter!, cancellation: cancellation),
    );
  }

  @override
  Future<List<AudioTrack>> loadFollowingTracks(String collectionId, {required String afterTrackId, required int limit}) async {
    if (limit <= 0) return const <AudioTrack>[];
    final detail = await _loadDetail(collectionId);
    if (detail.summary.id != collectionId || detail.summary.contentKind != PluginContentKind.audio) {
      return const <AudioTrack>[];
    }
    final catalog = await _loadCatalog(collectionId);
    final available = _availableChapters(catalog.items);
    final currentIndex = available.indexWhere((chapter) => chapter.id == afterTrackId);
    if (currentIndex < 0) return const <AudioTrack>[];
    final following = available.skip(currentIndex + 1).take(limit).toList(growable: false);
    if (following.isEmpty) return const <AudioTrack>[];
    return _runResourceRequest((cancellation) async {
      final tracks = <AudioTrack>[];
      for (final chapter in following) {
        try {
          tracks.add(await _loadTrack(detail: detail, collectionId: collectionId, chapter: chapter, cancellation: cancellation));
        } on AudioPlayerLoadException catch (error) {
          if (error.code != 'audio_resource_missing') rethrow;
          // A structurally missing resource is the only safe reason to skip a
          // chapter. Network/Runtime failures must stop this bounded batch so
          // a later retry cannot silently jump over unheard content.
        } on Object catch (error) {
          throw AudioPlayerLoadException(
            code: 'audio_continuation_unavailable',
            location: '下一章节的播放地址',
            message: '下一章节暂时无法加载，请检查网络后重试。',
            debugDetail: _sourceFailureDetail(error),
          );
        }
      }
      if (tracks.isEmpty) {
        throw const AudioPlayerLoadException(
          code: 'audio_continuation_unavailable',
          location: '下一章节的播放地址',
          message: '下一章节暂时无法加载，请检查网络后重试。',
        );
      }
      return tracks;
    });
  }

  Future<T> _runResourceRequest<T>(Future<T> Function(PluginInvocationCancellation cancellation) operation) async {
    _resourceCancellation?.cancel();
    final cancellation = PluginInvocationCancellation();
    final requestId = ++_resourceRequestId;
    _resourceCancellation = cancellation;
    try {
      return await operation(cancellation);
    } finally {
      if (_resourceRequestId == requestId && identical(_resourceCancellation, cancellation)) {
        _resourceCancellation = null;
      }
    }
  }

  Future<PluginContentDetail> _loadDetail(String collectionId) async {
    _bindCache(collectionId);
    final cached = _detailFuture;
    if (cached != null) return cached;
    final request = initialDetail?.summary.id == collectionId
        ? Future<PluginContentDetail>.value(initialDetail)
        : gateway.getDetail(pluginId: pluginId, id: collectionId);
    _detailFuture = request;
    try {
      return await request;
    } on Object catch (error) {
      if (identical(_detailFuture, request)) _detailFuture = null;
      if (error is AudioPlayerLoadException) rethrow;
      throw AudioPlayerLoadException(
        code: 'audio_detail_load_failed',
        location: '音频详情请求',
        message: '数据源音频详情加载失败。',
        debugDetail: _sourceFailureDetail(error),
      );
    }
  }

  Future<PluginChaptersResult> _loadCatalog(String collectionId) async {
    _bindCache(collectionId);
    final cached = _catalogFuture;
    if (cached != null) return cached;
    final request = initialDetail?.summary.id == collectionId && initialCatalog != null
        ? Future<PluginChaptersResult>.value(initialCatalog)
        : gateway.getChapters(pluginId: pluginId, id: collectionId);
    _catalogFuture = request;
    try {
      return await request;
    } on Object catch (error) {
      if (identical(_catalogFuture, request)) _catalogFuture = null;
      if (error is AudioPlayerLoadException) rethrow;
      throw AudioPlayerLoadException(
        code: 'audio_catalog_load_failed',
        location: '音频目录请求',
        message: '数据源音频目录加载失败。',
        debugDetail: _sourceFailureDetail(error),
      );
    }
  }

  void _bindCache(String collectionId) {
    if (_cachedCollectionId == collectionId) return;
    _cachedCollectionId = collectionId;
    _detailFuture = null;
    _catalogFuture = null;
  }

  Future<AudioTrack> _loadTrack({
    required PluginContentDetail detail,
    required String collectionId,
    required PluginChapterSummary chapter,
    required PluginInvocationCancellation cancellation,
  }) async {
    late final PluginChapterContent content;
    try {
      content = await runCancellableSourceRequest(
        gateway,
        cancellation,
        () => gateway.getContent(pluginId: pluginId, id: collectionId, chapterId: chapter.id),
      );
    } on Object catch (error) {
      if (error is AudioPlayerLoadException) rethrow;
      throw AudioPlayerLoadException(
        code: 'audio_resource_request_failed',
        location: '章节播放地址解析',
        message: '数据源解析“${chapter.title}”的播放地址失败。',
        debugDetail: _sourceFailureDetail(error),
      );
    }
    final media = content.media;
    if (content.contentKind != PluginContentKind.audio || media == null) {
      throw const AudioPlayerLoadException(code: 'audio_resource_missing', location: '播放地址', message: '数据源没有返回该章节的可播放地址。');
    }
    return AudioTrack(
      id: chapter.id,
      title: chapter.title,
      collectionTitle: detail.summary.title,
      creator: detail.summary.author,
      resource: media.url,
      artwork: detail.summary.coverUrl,
      resourcePolicy: media.resourcePolicy == PluginMediaResourcePolicy.refreshable
          ? AudioResourcePolicy.refreshable
          : AudioResourcePolicy.sessionOnly,
      expiresAt: media.expiresAt,
      httpHeaders: media.headers,
    );
  }
}

String _sourceFailureDetail(Object error) {
  final text = error.toString().trim();
  final detail = text.isEmpty ? error.runtimeType.toString() : text;
  return detail.length <= 512 ? detail : detail.substring(0, 512);
}
