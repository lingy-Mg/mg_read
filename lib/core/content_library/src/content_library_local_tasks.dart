/// Durable local-import journal and cancellable worker lifecycle. File copying
/// and parsing precede metadata visibility; interrupted work is never a book.
part of 'content_library.dart';

void _validateLocalJob(JsonObject v) {
  LocalImportSnapshot.fromJson(v);
  if ((v['fileName']! as String).length > 1024 || (v['id']! as String).length > 128) {
    throw const FormatException('invalid_local_import_job');
  }
}

final class _LocalImportOperation {
  final cancellation = LocalDocumentCancellation();
  final cancelled = Completer<void>();
  final done = Completer<void>();
  Isolate? isolate;
  final progressClock = Stopwatch()..start();
  int lastProgressMs = -200;
  bool reportProgress() {
    final now = progressClock.elapsedMilliseconds;
    if (now - lastProgressMs < 200) return false;
    lastProgressMs = now;
    return true;
  }

  void cancel() {
    cancellation.cancel();
    if (!cancelled.isCompleted) cancelled.complete();
    isolate?.kill(priority: Isolate.immediate);
  }
}

extension LocalImportTasks on ContentLibrary {
  Stream<LocalImportSnapshot> get localImportEvents => _localImportEvents.stream;

  Future<List<LocalImportSnapshot>> localImportJobs() async {
    await (_localRecovery ??= _recoverLocalImports());
    await _pruneLocalImportJournal();
    final page = await _persistence.metadataRecords.list(const RecordQuery(recordKind: 'local_import_job', scope: _scope, limit: 1000));
    final jobs = page.records.map((row) => LocalImportSnapshot.fromJson(row.document)).toList()
      ..sort((a, b) {
        final aPending = !['succeeded', 'cancelled', 'failed'].contains(a.status.name);
        final bPending = !['succeeded', 'cancelled', 'failed'].contains(b.status.name);
        if (aPending != bPending) return aPending ? -1 : 1;
        return b.updatedAt.compareTo(a.updatedAt);
      });
    return jobs.take(100).toList(growable: false);
  }

  Future<LocalImportSnapshot> queueLocalImport(
    LocalImportInput input, {
    LocalDocumentParseOptions options = const LocalDocumentParseOptions(),
  }) async {
    if (_closing) throw StateError('ContentLibrary is closing');
    await (_localRecovery ??= _recoverLocalImports());
    await _pruneLocalImportJournal();
    final id = _id();
    final existing = await _persistence.metadataRecords.list(const RecordQuery(recordKind: 'local_import_job', scope: _scope, limit: 1000));
    if (existing.records.where((row) => !['succeeded', 'cancelled', 'failed'].contains(row.document['status'])).length >= 100) {
      throw const LocalDocumentException('import_queue_full');
    }
    final name = input.fileName.replaceAll('\\', '/').split('/').last;
    final snapshot = LocalImportSnapshot(
      id: id,
      fileName: name,
      status: LocalImportStatus.queued,
      updatedAt: DateTime.now().toUtc(),
      totalBytes: input.bytes,
      options: options,
    );
    await _saveLocalJob(snapshot.toJson());
    return snapshot;
  }

  Future<LocalImportSnapshot> prepareLocalImport(
    LocalImportInput input, {
    LocalDocumentParseOptions options = const LocalDocumentParseOptions(),
    LibraryItemId? replaceItemId,
    String? queuedJobId,
  }) async {
    if (_closing) throw StateError('ContentLibrary is closing');
    final id = queuedJobId ?? (await queueLocalImport(input, options: options)).id;
    if (queuedJobId != null && (await _localJob(id))['status'] != 'queued') throw const LocalDocumentException('task_finished');
    final op = _LocalImportOperation();
    _localImports[id] = op;
    final fileName = input.fileName.replaceAll('\\', '/').split('/').last;
    final format = fileName.toLowerCase().endsWith('.epub')
        ? LocalDocumentFormat.epub
        : fileName.toLowerCase().endsWith('.txt')
        ? LocalDocumentFormat.txt
        : null;
    final record = <String, Object?>{
      'id': id,
      'fileName': fileName,
      'status': 'queued',
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
      'totalBytes': input.bytes,
      'format': format?.name,
      'options': options.toJson(),
      'replaceItemId': replaceItemId?.value,
    };
    try {
      await _saveLocalJob(record);
      if (format == null) throw const LocalDocumentException('unsupported_format');
      if (input.bytes != null && input.bytes! > localDocumentMaxFileBytes) throw const LocalDocumentException('file_too_large');
      final stage = await _localFiles.staging(id);
      final available = await availableLocalDocumentBytes(stage);
      if (available != null && available < (input.bytes ?? 0) + 16 * 1024 * 1024) {
        throw const LocalDocumentException('disk_full');
      }
      record['status'] = 'acquiring';
      await _saveLocalJob(record);
      final raw = File('${stage.path}/source');
      final sink = raw.openWrite();
      final capture = _LocalDigestCapture();
      final hash = document_crypto.sha256.startChunkedConversion(capture);
      final iterator = StreamIterator(input.openRead());
      var bytes = 0;
      var pendingBytes = 0;
      try {
        while (await Future.any<bool>([
          iterator.moveNext().timeout(const Duration(seconds: 30)),
          op.cancelled.future.then((_) => throw const LocalDocumentException('cancelled')),
        ])) {
          op.cancellation.check();
          final chunk = iterator.current;
          bytes += chunk.length;
          if (bytes > localDocumentMaxFileBytes) throw const LocalDocumentException('file_too_large');
          sink.add(chunk);
          hash.add(chunk);
          pendingBytes += chunk.length;
          if (pendingBytes >= 256 * 1024) {
            await sink.flush();
            pendingBytes = 0;
          }
          if (op.reportProgress()) _emitLocalJob({...record, 'completedBytes': bytes});
        }
      } finally {
        await iterator.cancel();
        hash.close();
        await sink.close();
      }
      if (bytes == 0) throw const LocalDocumentException('empty_document');
      if (input.bytes != null && input.bytes != bytes) throw const LocalDocumentException('source_changed');
      if (input.expectedSha256 != null && input.expectedSha256 != capture.value!.toString()) {
        throw const LocalDocumentException('checksum_mismatch');
      }
      record.addAll({'completedBytes': bytes, 'totalBytes': bytes, 'rawSha256': capture.value!.toString(), 'status': 'inspecting'});
      if (replaceItemId != null) {
        final existing = await getLibraryItem(replaceItemId);
        if (existing == null || !existing.source.isLocal) throw const LocalDocumentException('item_missing');
        record['expectedRevision'] = existing.revision;
      }
      await _saveLocalJob(record);
      await _parseLocalDraft(record, op);
      return LocalImportSnapshot.fromJson(record);
    } on Object catch (error) {
      await _failLocalJob(record, error);
      return LocalImportSnapshot.fromJson(record);
    } finally {
      _localImports.remove(id);
      if (!op.done.isCompleted) op.done.complete();
    }
  }

  Future<LocalImportSnapshot> reparseLocalImport(String id, LocalDocumentParseOptions options) async {
    if (_localImports.containsKey(id)) throw const LocalDocumentException('task_busy');
    final record = await _localJob(id);
    if (record['status'] == 'succeeded' || record['status'] == 'cancelled') throw const LocalDocumentException('task_finished');
    final op = _LocalImportOperation();
    _localImports[id] = op;
    try {
      final stage = await _localFiles.staging(id);
      if (record['rawSha256'] is String) await _localFiles.restoreDraft(id, record['rawSha256']! as String);
      if (!await File('${stage.path}/source').exists() || record['rawSha256'] == null) {
        throw const LocalDocumentException('reselect_file');
      }
      final parsed = Directory('${stage.path}/parsed');
      // This exact child is app-created staging, never a supplied pathname.
      if (await parsed.exists()) await parsed.delete(recursive: true);
      record['options'] = options.toJson();
      await _parseLocalDraft(record, op);
    } on Object catch (error) {
      await _failLocalJob(record, error);
    } finally {
      _localImports.remove(id);
      op.done.complete();
    }
    return LocalImportSnapshot.fromJson(record);
  }

  Future<void> cancelLocalImport(String id) async {
    final op = _localImports[id];
    if (op != null) {
      op.cancel();
      await op.done.future;
      return;
    }
    final record = await _localJob(id);
    if (record['status'] == 'succeeded') return;
    record['status'] = 'cancelled';
    await _saveLocalJob(record);
    await _localFiles.removeStaging(id);
  }

  Future<void> _parseLocalDraft(Map<String, Object?> record, _LocalImportOperation op) async {
    op.cancellation.check();
    final id = record['id']! as String;
    final stage = await _localFiles.staging(id);
    final output = Directory('${stage.path}/parsed');
    await output.create(recursive: true);
    record.addAll({'status': 'parsing', 'errorCode': null, 'errorDetail': null});
    await _saveLocalJob(record);
    final port = ReceivePort();
    final result = Completer<ParsedLocalDocument>();
    final subscription = port.listen((message) {
      if (message is Map && message['document'] is Map) {
        if (!result.isCompleted) result.complete(ParsedLocalDocument.fromJson(Map<String, Object?>.from(message['document'] as Map)));
      } else if (message is Map && message['error'] is String) {
        if (!result.isCompleted) result.completeError(LocalDocumentException(message['error']! as String, message['detail'] as String?));
      } else if (message is List && message.length == 2) {
        if (!result.isCompleted) result.completeError(const LocalDocumentException('parser_crashed'));
      } else if (message == null && !result.isCompleted) {
        result.completeError(const LocalDocumentException('parser_crashed'));
      } else if (message is List && message.length == 3) {
        if (op.reportProgress()) _emitLocalJob({...record, 'workCompleted': message[1], 'workTotal': message[2], 'workStage': message[0]});
      }
    });
    try {
      op.isolate = await Isolate.spawn(
        _parseLocalDocumentWorker,
        [port.sendPort, record['format'], '${stage.path}/source', output.path, record['options']],
        onError: port.sendPort,
        onExit: port.sendPort,
        errorsAreFatal: true,
        debugName: 'local-document-parser',
      );
      var document = await Future.any<ParsedLocalDocument>([
        result.future.timeout(const Duration(minutes: 10)),
        op.cancelled.future.then((_) => throw const LocalDocumentException('cancelled')),
      ]);
      if (document.title == 'source' || document.title == 'Untitled') {
        document = ParsedLocalDocument.fromJson({
          ...document.toJson(),
          'title': (record['fileName']! as String).replaceFirst(RegExp(r'\.(txt|epub)$', caseSensitive: false), ''),
        });
      }
      op.cancellation.check();
      if (document.chapters.isEmpty || document.chapters.length > localDocumentMaxEntries) {
        throw const LocalDocumentException('invalid_catalog');
      }
      final duplicate = await _persistence.metadataRecords.contentLibrary.localItemByHash(record['rawSha256']! as String);
      final manifest = <String, Object?>{
        'document': document.toJson(),
        'rawSha256': record['rawSha256'],
        'originalBytes': record['totalBytes'],
        'options': record['options'],
      };
      await _writeLocalJson('${output.path}/manifest.json', manifest);
      record.addAll({
        'status': 'awaitingConfirmation',
        'title': document.title,
        'author': document.author,
        'encoding': document.encoding,
        'chapterCount': document.logicalChapterCount,
        'wordCount': document.wordCount,
        'warnings': document.warnings.take(100).toList(),
        'isDuplicate': duplicate != null,
        if (duplicate != null) 'itemId': duplicate.itemId,
      });
      await _saveLocalJob(record);
    } finally {
      op.isolate?.kill(priority: Isolate.immediate);
      op.isolate = null;
      await subscription.cancel();
      port.close();
    }
  }

  Future<Map<String, Object?>> _localJob(String id) async {
    final row = await _persistence.metadataRecords.read(id: id, scope: _scope);
    if (row == null || row.recordKind != 'local_import_job') throw const LocalDocumentException('task_missing');
    return Map<String, Object?>.from(row.document);
  }

  void _emitLocalJob(Map<String, Object?> record) {
    if (!_localImportEvents.isClosed) _localImportEvents.add(LocalImportSnapshot.fromJson(record));
  }

  Future<void> _saveLocalJob(Map<String, Object?> record) async {
    record['updatedAt'] = DateTime.now().toUtc().toIso8601String();
    final row = await _persistence.metadataRecords.read(id: record['id']! as String, scope: _scope);
    await _persistence.metadataRecords.writeDocumentsCas([
      RecordDocumentWrite(
        id: record['id']! as String,
        recordKind: 'local_import_job',
        scope: _scope,
        expectedRevision: row?.revision,
        document: record,
      ),
    ]);
    _emitLocalJob(record);
  }

  Future<void> _failLocalJob(Map<String, Object?> record, Object error) async {
    assert(() {
      stderr.writeln("Local import failed: $error");
      return true;
    }());
    final code = error is LocalDocumentException
        ? error.code
        : error is PersistenceCapacityError
        ? 'bookshelf_full'
        : error is FileSystemException && {28, 39, 112}.contains(error.osError?.errorCode)
        ? 'disk_full'
        : 'import_failed';
    record.addAll({
      'status': code == 'cancelled'
          ? 'cancelled'
          : ['encoding_required', 'reselect_file', 'bookshelf_full', 'disk_full'].contains(code)
          ? 'needsAction'
          : 'failed',
      'errorCode': code,
      'errorDetail': error is LocalDocumentException ? error.detail : null,
    });
    await _saveLocalJob(record);
    if (code == 'cancelled') await _localFiles.removeStaging(record['id']! as String);
  }

  Future<void> _recoverLocalImports() async {
    final rows = await _persistence.metadataRecords.list(const RecordQuery(recordKind: 'local_import_job', scope: _scope, limit: 1000));
    final items = await _persistence.metadataRecords.contentLibrary.localItems();
    for (final row in rows.records) {
      final record = Map<String, Object?>.from(row.document);
      if (_localImports.containsKey(row.id)) continue;
      if (['queued', 'acquiring', 'inspecting', 'parsing', 'validating', 'committing'].contains(record['status'])) {
        final committed = items.where((item) => item.values['active_generation'] == row.id).firstOrNull;
        record.addAll(
          committed == null
              ? {'status': 'interrupted', 'errorCode': 'interrupted'}
              : {'status': 'succeeded', 'itemId': committed.itemId, 'errorCode': null},
        );
        if (committed == null && record['rawSha256'] is String) {
          await _localFiles.restoreDraft(row.id, record['rawSha256']! as String);
        }
        await _saveLocalJob(record);
      }
    }
  }
}

final class _LocalDigestCapture implements Sink<document_crypto.Digest> {
  document_crypto.Digest? value;
  @override
  void add(document_crypto.Digest data) => value = data;
  @override
  void close() {}
}

Future<void> _parseLocalDocumentWorker(List<Object?> args) async {
  final port = args[0]! as SendPort;
  try {
    final LocalDocumentParser parser = args[1] == 'epub' ? EpubLocalDocumentParser() : TxtLocalDocumentParser();
    final result = await parser.parse(
      source: File(args[2]! as String),
      output: Directory(args[3]! as String),
      options: LocalDocumentParseOptions.fromJson(Map<String, Object?>.from(args[4]! as Map)),
      onProgress: (stage, completed, total) => port.send([stage, completed, total]),
    );
    port.send({'document': result.toJson()});
  } on Object catch (error) {
    port.send({
      'error': error is LocalDocumentException
          ? error.code
          : error is FileSystemException && {28, 39, 112}.contains(error.osError?.errorCode)
          ? 'disk_full'
          : 'parse_failed',
      'detail': error is LocalDocumentException ? error.detail : null,
    });
  }
}
