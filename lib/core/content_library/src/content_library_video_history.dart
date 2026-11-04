/// Bounded video history and per-device branches, owned by ContentLibrary.
/// Remote branches persist before the resume-pointer compare-and-swap so a
/// conflict never discards the received checkpoint.
part of 'content_library.dart';

const _videoHistoryKind = 'video-history-checkpoint';
const _videoGenerationKind = 'video-history-generation';
const _videoHistoryScope = ScopeKey(kind: 'video_history', id: 'primary');
const _videoHistoryMaxRecords = 500;

Iterable<RecordDocumentCodec> get videoHistoryRecordDocumentCodecs sync* {
  yield RecordDocumentCodec(
    recordKind: _videoGenerationKind,
    scopeKind: _videoHistoryScope.kind,
    currentVersion: 1,
    validators: {
      1: (json) {
        final generation = json['generation'];
        if (json.length != 1 || generation is! int || generation < 1 || generation > 9007199254740991) {
          throw const FormatException('video_history_generation');
        }
      },
    },
  );
  yield RecordDocumentCodec(
    recordKind: _videoHistoryKind,
    scopeKind: _videoHistoryScope.kind,
    currentVersion: 1,
    validators: {
      1: (json) {
        VideoHistoryCheckpoint.fromJson(json);
      },
    },
    inlinePreparationPolicy: const JsonInlinePreparationPolicy(
      maxDocuments: 2,
      maxTotalNodes: 64,
      maxDepth: 2,
      maxCollectionLength: 24,
      maxTotalTextCodeUnits: 12288,
    ),
  );
}

extension ContentLibraryVideoHistory on ContentLibrary {
  /// Reserves a durable monotonic generation once per local playback session.
  /// The counter is per originating device, independent from resume-pointer
  /// revisions, and cannot be raised by a delayed remote checkpoint.
  Future<int> allocateVideoHistoryGeneration(String originDeviceId) async {
    if (originDeviceId.isEmpty || originDeviceId.length > 128) throw ArgumentError.value(originDeviceId, 'originDeviceId');
    final records = _persistence.metadataRecords;
    final id = 'video-generation:${videoHistoryRecordId(originDeviceId)}';
    for (var attempt = 0; attempt < 8; attempt++) {
      final current = await records.read(id: id, scope: _videoHistoryScope);
      var generation = (current?.document['generation'] as int? ?? 0) + 1;
      if (current == null) {
        final retained = await listVideoHistory(limit: 500, includeRemoteBranches: true);
        for (final entry in retained) {
          if (entry.checkpoint.originDeviceId == originDeviceId && entry.checkpoint.localGeneration >= generation) {
            generation = entry.checkpoint.localGeneration + 1;
          }
        }
      }
      try {
        if (current == null) {
          await records.create(
            RecordDraft(id: id, recordKind: _videoGenerationKind, scope: _videoHistoryScope, document: {'generation': generation}),
          );
        } else {
          await records.update(previous: current, document: {'generation': generation});
        }
        return generation;
      } on PersistenceConflictError {
        /* Another local player reserved first. */
      }
    }
    throw const PersistenceConflictError();
  }

  Future<VideoHistoryEntry?> readVideoHistory(String sourceKey) async {
    final record = await _persistence.metadataRecords.read(id: videoHistoryRecordId(sourceKey), scope: _videoHistoryScope);
    return record == null
        ? null
        : VideoHistoryEntry(checkpoint: VideoHistoryCheckpoint.fromJson(record.document), revision: record.revision);
  }

  Future<List<VideoHistoryEntry>> listVideoHistory({int limit = 100, bool includeRemoteBranches = false}) async {
    if (limit < 1 || limit > _videoHistoryMaxRecords) throw ArgumentError.value(limit, 'limit');
    final page = await _persistence.metadataRecords.list(
      RecordQuery(recordKind: _videoHistoryKind, scope: _videoHistoryScope, limit: _videoHistoryMaxRecords),
    );
    final entries = <VideoHistoryEntry>[];
    for (final record in page.records) {
      final checkpoint = VideoHistoryCheckpoint.fromJson(record.document);
      final isResumePointer = record.id == videoHistoryRecordId(checkpoint.sourceKey);
      if (includeRemoteBranches || isResumePointer) {
        entries.add(VideoHistoryEntry(checkpoint: checkpoint, revision: record.revision));
      }
    }
    entries.sort((a, b) => b.checkpoint.updatedAtUtc.compareTo(a.checkpoint.updatedAtUtc));
    return List<VideoHistoryEntry>.unmodifiable(entries.take(limit));
  }

  /// Local writes may omit [expectedLocalRevision]. Remote writes must provide
  /// the revision they observed; zero means there was no resume pointer.
  ///
  /// Each device branch has its own generation/session/sequence fence. A
  /// branch is committed first, then the resume pointer is updated with CAS.
  Future<VideoHistorySaveResult> saveVideoHistory(
    VideoHistoryCheckpoint checkpoint, {
    int? expectedLocalRevision,
    bool remote = false,
  }) async {
    // Reuse the persisted schema validator for values created in process too.
    checkpoint = VideoHistoryCheckpoint.fromJson(checkpoint.toJson());
    if (remote && expectedLocalRevision == null) {
      throw ArgumentError('remote checkpoint requires expectedLocalRevision');
    }
    if (expectedLocalRevision != null && expectedLocalRevision < 0) {
      throw ArgumentError.value(expectedLocalRevision, 'expectedLocalRevision');
    }

    final records = _persistence.metadataRecords;
    final branchId = videoHistoryRecordId(checkpoint.sourceKey, origin: checkpoint.originDeviceId);
    final resumeId = videoHistoryRecordId(checkpoint.sourceKey);
    final branch = await records.read(id: branchId, scope: _videoHistoryScope);
    if (branch != null) {
      final previousBranch = VideoHistoryCheckpoint.fromJson(branch.document);
      final branchOrder = _compareSameOrigin(previousBranch, checkpoint);
      if (branchOrder == _VideoHistoryOrder.duplicate) {
        return VideoHistorySaveResult(VideoHistorySaveStatus.duplicate, (await readVideoHistory(checkpoint.sourceKey))?.revision ?? 0);
      }
      if (branchOrder != _VideoHistoryOrder.newer) {
        return VideoHistorySaveResult(VideoHistorySaveStatus.conflict, (await readVideoHistory(checkpoint.sourceKey))?.revision ?? 0);
      }
    }

    try {
      if (branch == null) {
        await records.create(
          RecordDraft(id: branchId, recordKind: _videoHistoryKind, scope: _videoHistoryScope, document: checkpoint.toJson()),
        );
      } else {
        await records.update(previous: branch, document: checkpoint.toJson());
      }
    } on PersistenceConflictError {
      return VideoHistorySaveResult(VideoHistorySaveStatus.conflict, (await readVideoHistory(checkpoint.sourceKey))?.revision ?? 0);
    }

    final current = await records.read(id: resumeId, scope: _videoHistoryScope);
    final currentRevision = current?.revision ?? 0;
    if (expectedLocalRevision != null && currentRevision != expectedLocalRevision) {
      await _trimVideoHistory(protectIds: {branchId, resumeId});
      return VideoHistorySaveResult(VideoHistorySaveStatus.conflict, currentRevision);
    }
    if (current != null) {
      final previous = VideoHistoryCheckpoint.fromJson(current.document);
      if (previous.originDeviceId == checkpoint.originDeviceId) {
        final pointerOrder = _compareSameOrigin(previous, checkpoint);
        if (pointerOrder == _VideoHistoryOrder.duplicate) {
          await _trimVideoHistory(protectIds: {branchId, resumeId});
          return VideoHistorySaveResult(VideoHistorySaveStatus.duplicate, current.revision);
        }
        if (pointerOrder != _VideoHistoryOrder.newer) {
          await _trimVideoHistory(protectIds: {branchId, resumeId});
          return VideoHistorySaveResult(VideoHistorySaveStatus.conflict, current.revision);
        }
      }
    }

    late final RecordEnvelope updated;
    try {
      updated = current == null
          ? await records.create(
              RecordDraft(id: resumeId, recordKind: _videoHistoryKind, scope: _videoHistoryScope, document: checkpoint.toJson()),
            )
          : await records.update(previous: current, document: checkpoint.toJson());
    } on PersistenceConflictError {
      await _trimVideoHistory(protectIds: {branchId, resumeId});
      return VideoHistorySaveResult(VideoHistorySaveStatus.conflict, (await readVideoHistory(checkpoint.sourceKey))?.revision ?? 0);
    }
    await _trimVideoHistory(protectIds: {branchId, resumeId});
    return VideoHistorySaveResult(VideoHistorySaveStatus.committed, updated.revision);
  }

  Future<void> _trimVideoHistory({required Set<String> protectIds}) async {
    final records = _persistence.metadataRecords;
    while (true) {
      final page = await records.list(RecordQuery(recordKind: _videoHistoryKind, scope: _videoHistoryScope, limit: 1000));
      final excess = page.records.length - _videoHistoryMaxRecords;
      if (excess <= 0) return;

      final candidates = <({RecordEnvelope record, bool isResume, DateTime updatedAt})>[];
      for (final record in page.records) {
        if (protectIds.contains(record.id)) continue;
        final checkpoint = VideoHistoryCheckpoint.fromJson(record.document);
        final isResume = record.id == videoHistoryRecordId(checkpoint.sourceKey);
        candidates.add((record: record, isResume: isResume, updatedAt: checkpoint.updatedAtUtc));
      }
      // Keep current resume pointers ahead of old branch copies. Timestamps are
      // only an eviction tie-breaker and never decide whether a save is newer.
      candidates.sort((a, b) {
        final kindOrder = a.isResume == b.isResume ? 0 : (a.isResume ? 1 : -1);
        return kindOrder != 0 ? kindOrder : a.updatedAt.compareTo(b.updatedAt);
      });
      var deleted = 0;
      for (final candidate in candidates) {
        if (deleted >= excess) break;
        try {
          await records.delete(previous: candidate.record);
          deleted++;
        } on PersistenceConflictError {
          // A concurrent update owns the newer revision; leave it in place.
        }
      }
      if (deleted == 0) return;
    }
  }
}

enum _VideoHistoryOrder { newer, duplicate, stale, sessionConflict }

_VideoHistoryOrder _compareSameOrigin(VideoHistoryCheckpoint previous, VideoHistoryCheckpoint incoming) {
  if (incoming.localGeneration < previous.localGeneration) return _VideoHistoryOrder.stale;
  if (incoming.localGeneration > previous.localGeneration) return _VideoHistoryOrder.newer;
  if (incoming.playbackSessionId != previous.playbackSessionId) return _VideoHistoryOrder.sessionConflict;
  if (incoming.sequence < previous.sequence) return _VideoHistoryOrder.stale;
  if (incoming.sequence == previous.sequence) return _VideoHistoryOrder.duplicate;
  return _VideoHistoryOrder.newer;
}
