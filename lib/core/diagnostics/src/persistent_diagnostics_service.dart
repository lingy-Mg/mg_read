part of 'persistent_diagnostics.dart';

final class AppDiagnosticsService
    implements DiagnosticsQuery, DiagnosticsCapture, DiagnosticsMaintenance {
  AppDiagnosticsService._({
    required this.manager,
    required this._sink,
    required this._persistence,
    required this.configuration,
    required this.sourceRunId,
    required this._idGenerator,
    required this._runSpan,
  });

  final DiagnosticsManager manager;
  final _PersistentDiagnosticEventSink _sink;
  final DiagnosticsPersistence _persistence;
  final PersistentDiagnosticsConfiguration configuration;
  final String sourceRunId;
  final DiagnosticIdGenerator _idGenerator;
  final DiagnosticSpanHandle _runSpan;
  DiagnosticStoredCaptureSession? _activeCapture;
  DiagnosticSpanHandle? _captureSpan;
  Timer? _captureExpiryTimer;
  Future<void> _attachmentWriteTail = Future<void>.value();
  Future<void>? _closeFuture;
  bool _closing = false;
  bool _closed = false;

  DiagnosticWriterStatistics get writerStatistics => _sink.statistics;

  static Future<AppDiagnosticsService> open({
    required Directory dataRoot,
    PersistentDiagnosticsConfiguration configuration =
        const PersistentDiagnosticsConfiguration(),
    DiagnosticIdGenerator? idGenerator,
    DiagnosticClock? clock,
    DiagnosticEventRegistry? registry,
    DiagnosticPrivacyPolicy? privacyPolicy,
    String buildMode = 'debug',
    String platform = 'unknown',
    bool deferStartupMaintenance = false,
  }) async {
    configuration.validate();
    final ids = idGenerator ?? SecureDiagnosticIdGenerator();
    final effectiveClock = clock ?? const SystemDiagnosticClock();
    final sourceRunId = ids.nextId('run');
    final persistence = await DiagnosticsPersistence.open(
      dataRoot: dataRoot,
      clock: effectiveClock.nowUtc,
      detailMemoryBytes: configuration.detailMemoryBytes,
    );
    // Retention can compact a large interrupted diagnostics history. It is
    // maintenance rather than a prerequisite for accepting new diagnostics,
    // so the Flutter bootstrap may defer it until after the first frame.
    if (!deferStartupMaintenance) {
      await persistence.enforceRetention(configuration.retentionPolicy);
    }
    await persistence.beginRun(
      sourceRunId: sourceRunId,
      source: DiagnosticSource.app,
      regularSessionMaxBytes: configuration.retentionPolicy.regularEventBytes,
      regularSessionAge: configuration.retentionPolicy.regularEventAge,
    );
    final sink = _PersistentDiagnosticEventSink(
      persistence: persistence,
      configuration: configuration,
    );
    final manager = DiagnosticsManager(
      sink: sink,
      registry: registry ?? AppDiagnosticEvents.registry,
      source: DiagnosticSource.app,
      privacyPolicy: privacyPolicy,
      idGenerator: ids,
      clock: effectiveClock,
      sourceRunId: sourceRunId,
      buildMode: buildMode,
      platform: platform,
    );
    final runSpan = manager.startSpan(
      AppDiagnosticEvents.diagnosticsRun,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'buildMode': DiagnosticValue.string(buildMode),
        'platform': DiagnosticValue.string(platform),
      }),
    );
    final service = AppDiagnosticsService._(
      manager: manager,
      sink: sink,
      persistence: persistence,
      configuration: configuration,
      sourceRunId: sourceRunId,
      idGenerator: ids,
      runSpan: runSpan,
    );
    sink.activeSessionResolver = service._activeSessionForEvent;
    sink.captureEnabledResolver = service._isCaptureEnabledForComponent;
    sink.dropReporter = service._reportDrops;
    manager.emit(
      AppDiagnosticEvents.writerState,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'state': DiagnosticValue.string('ready'),
        'queueDepth': DiagnosticValue.int64(sink.statistics.queueDepth),
        'queueBytes': DiagnosticValue.int64(sink.statistics.queueBytes),
      }),
    );
    return service;
  }

  @override
  Future<DiagnosticPage<DiagnosticSession>> listSessions({
    DiagnosticSessionFilter filter = const DiagnosticSessionFilter(),
    DiagnosticCursor? cursor,
    int limit = 100,
  }) async {
    await _sink.flush(timeout: const Duration(milliseconds: 500));
    return _persistence.listSessions(
      filter: filter,
      cursor: cursor,
      limit: limit,
    );
  }

  @override
  Future<DiagnosticPage<DiagnosticEvent>> listEvents({
    required DiagnosticEventFilter filter,
    DiagnosticCursor? cursor,
    int limit = 100,
  }) async {
    await _sink.flush(timeout: const Duration(milliseconds: 500));
    return _persistence.listEvents(
      filter: filter,
      cursor: cursor,
      limit: limit,
    );
  }

  @override
  Future<DiagnosticEvent?> getEvent(String eventId) async {
    await _sink.flush(timeout: const Duration(milliseconds: 500));
    return _persistence.getEvent(eventId);
  }

  @override
  Future<List<DiagnosticAttachmentDescriptor>> listAttachments(
    String eventId,
  ) => _persistence.listAttachments(eventId);

  @override
  Stream<List<int>> openAttachment(
    String attachmentId, {
    DiagnosticByteRange? range,
  }) => _persistence.openAttachment(attachmentId, range: range);

  @override
  Future<DiagnosticPage<DiagnosticStructuredNode>> listStructuredNodes(
    String attachmentId, {
    required String path,
    DiagnosticCursor? cursor,
    int limit = 100,
  }) {
    throw UnsupportedError(
      'Structured attachment paging is delivered with the diagnostics viewer.',
    );
  }

  @override
  Future<DiagnosticSession> startCapture(DiagnosticCapturePolicy policy) async {
    _ensureOpen();
    final span = manager.startSpan(
      AppDiagnosticEvents.capture,
      attributes: () => _captureAttributes(policy, sessionState: 'starting'),
    );
    try {
      if (policy.payloadKind == DiagnosticPayloadKind.restrictedRaw) {
        throw UnsupportedError(
          'restrictedRaw requires the separately approved encrypted D5 store.',
        );
      }
      if (_activeCapture != null) {
        throw StateError(
          'Only one explicit app capture session may be active.',
        );
      }
      final sessionId = _idGenerator.nextId('capture');
      if (policy.maxStoredBytes > configuration.retentionPolicy.captureBytes) {
        throw RangeError.range(
          policy.maxStoredBytes,
          1,
          configuration.retentionPolicy.captureBytes,
          'policy.maxStoredBytes',
        );
      }
      await _persistence.createCaptureSession(
        sessionId: sessionId,
        sourceRunId: sourceRunId,
        policy: policy,
      );
      _activeCapture = await _persistence.getCaptureSession(sessionId);
      _captureSpan = span;
      _captureExpiryTimer = Timer(policy.duration, () {
        unawaited(stopCapture(sessionId).catchError((_) {}));
      });
      return _activeCapture!.session;
    } catch (error, stackTrace) {
      span.fail(
        attributes: _captureAttributes(
          policy,
          sessionState: 'failed',
          errorCode: _captureErrorCode(error),
        ),
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  @override
  Future<void> stopCapture(String sessionId) async {
    _ensureOpen();
    final active = _activeCapture;
    try {
      await _persistence.stopCaptureSession(sessionId);
      if (active?.session.sessionId == sessionId) {
        _captureExpiryTimer?.cancel();
        _captureExpiryTimer = null;
        _activeCapture = null;
        if (_captureSpan case final span? when !span.isEnded) {
          span.complete(
            attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
              'sessionState': DiagnosticValue.string('ended'),
            }),
          );
        }
        _captureSpan = null;
      }
    } catch (error, stackTrace) {
      if (active?.session.sessionId == sessionId) {
        final span = _captureSpan;
        if (span != null && !span.isEnded) {
          span.fail(
            attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
              'sessionState': DiagnosticValue.string('stopFailed'),
              'errorCode': DiagnosticValue.string('capture_stop_failed'),
            }),
          );
          _captureSpan = null;
        }
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  @override
  Future<DiagnosticAttachmentDescriptor> captureAttachment({
    required String eventId,
    required String kind,
    required String mediaType,
    required String formatId,
    required int formatVersion,
    required DiagnosticPrivacyClass privacyClass,
    required Stream<List<int>> bytes,
    String? charset,
    String? schemaId,
    int? schemaVersion,
  }) {
    final operation = _attachmentWriteTail.then(
      (_) => _captureAttachment(
        eventId: eventId,
        kind: kind,
        mediaType: mediaType,
        formatId: formatId,
        formatVersion: formatVersion,
        privacyClass: privacyClass,
        bytes: bytes,
        charset: charset,
        schemaId: schemaId,
        schemaVersion: schemaVersion,
      ),
    );
    _attachmentWriteTail = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  Future<DiagnosticAttachmentDescriptor> _captureAttachment({
    required String eventId,
    required String kind,
    required String mediaType,
    required String formatId,
    required int formatVersion,
    required DiagnosticPrivacyClass privacyClass,
    required Stream<List<int>> bytes,
    String? charset,
    String? schemaId,
    int? schemaVersion,
  }) async {
    final span = manager.startSpan(
      AppDiagnosticEvents.attachment,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'kind': DiagnosticValue.string(kind),
        'privacyClass': DiagnosticValue.string(privacyClass.name),
      }),
    );
    try {
      final result = await _captureAttachmentCore(
        eventId: eventId,
        kind: kind,
        mediaType: mediaType,
        formatId: formatId,
        formatVersion: formatVersion,
        privacyClass: privacyClass,
        bytes: bytes,
        charset: charset,
        schemaId: schemaId,
        schemaVersion: schemaVersion,
      );
      final attributes = DiagnosticObjectValue(<String, DiagnosticValue>{
        'kind': DiagnosticValue.string(kind),
        'privacyClass': DiagnosticValue.string(privacyClass.name),
        'captureState': DiagnosticValue.string(result.captureState.name),
        'rawBytes': DiagnosticValue.int64(result.rawByteLength),
        'storedBytes': DiagnosticValue.int64(result.storedByteLength),
        if (result.captureState == DiagnosticCaptureState.failed)
          'errorCode': DiagnosticValue.string('attachment_failed'),
      });
      if (result.captureState == DiagnosticCaptureState.failed) {
        span.fail(attributes: attributes);
      } else {
        span.complete(attributes: attributes);
      }
      return result;
    } catch (error, stackTrace) {
      span.fail(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'kind': DiagnosticValue.string(kind),
          'privacyClass': DiagnosticValue.string(privacyClass.name),
          'captureState': DiagnosticValue.string('failed'),
          'errorCode': DiagnosticValue.string('attachment_failed'),
        }),
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<DiagnosticAttachmentDescriptor> _captureAttachmentCore({
    required String eventId,
    required String kind,
    required String mediaType,
    required String formatId,
    required int formatVersion,
    required DiagnosticPrivacyClass privacyClass,
    required Stream<List<int>> bytes,
    String? charset,
    String? schemaId,
    int? schemaVersion,
  }) async {
    _ensureOpen();
    await _sink.flush(timeout: configuration.defaultFlushTimeout);
    final event = await _persistence.getEvent(eventId);
    if (event == null) throw StateError('Diagnostic event does not exist.');
    final session = await _persistence.getCaptureSession(
      event.captureSessionId!,
    );
    final attachmentId = _idGenerator.nextId('attachment');
    String? blockedReason;
    if (session == null || session.isDefault) {
      blockedReason = 'explicitCaptureRequired';
    } else if (session.session.state != DiagnosticSessionState.active) {
      blockedReason = 'captureSessionInactive';
    } else if (privacyClass == DiagnosticPrivacyClass.secret) {
      blockedReason = 'secretNeverPersisted';
    } else if (privacyClass == DiagnosticPrivacyClass.restricted) {
      blockedReason = 'restrictedRawUnsupported';
    } else if (!_isTextDiagnosticMediaType(mediaType)) {
      blockedReason = 'textDetailsOnly';
    } else if (privacyClass == DiagnosticPrivacyClass.content &&
        session.session.payloadKind == DiagnosticPayloadKind.metadataOnly) {
      blockedReason = 'payloadModeBlocked';
    } else if (privacyClass == DiagnosticPrivacyClass.content &&
        session.session.payloadKind == DiagnosticPayloadKind.safeStructured &&
        !_isStructuredDiagnosticMediaType(mediaType)) {
      blockedReason = 'safeStructuredRequiresJson';
    } else if (session.remainingBytes <= 0) {
      blockedReason = 'captureSessionQuota';
    }
    if (blockedReason != null) {
      final descriptor = _descriptor(
        attachmentId: attachmentId,
        eventId: eventId,
        kind: kind,
        mediaType: mediaType,
        charset: charset,
        formatId: formatId,
        formatVersion: formatVersion,
        schemaId: schemaId,
        schemaVersion: schemaVersion,
        privacyClass: privacyClass,
        captureState: DiagnosticCaptureState.policyBlocked,
        rawByteLength: 0,
        storedByteLength: 0,
        truncationReason: blockedReason,
      );
      return _persistence.commitAttachment(
        descriptor: descriptor,
        objectKey: null,
      );
    }
    final maxBytes = min(
      configuration.retentionPolicy.singleAttachmentBytes,
      session!.remainingBytes,
    );
    try {
      final statistics = await _persistence.getStatistics();
      final globalRemaining =
          configuration.retentionPolicy.globalHardBytes -
          statistics.logicalStoredBytes;
      if (globalRemaining <= 0) {
        final descriptor = _descriptor(
          attachmentId: attachmentId,
          eventId: eventId,
          kind: kind,
          mediaType: mediaType,
          charset: charset,
          formatId: formatId,
          formatVersion: formatVersion,
          schemaId: schemaId,
          schemaVersion: schemaVersion,
          privacyClass: privacyClass,
          captureState: DiagnosticCaptureState.pressureDropped,
          rawByteLength: 0,
          storedByteLength: 0,
          truncationReason: 'globalDiagnosticsQuota',
        );
        return _persistence.commitAttachment(
          descriptor: descriptor,
          objectKey: null,
        );
      }
      final effectiveMaxBytes = min(maxBytes, globalRemaining);
      final commit = await _persistence.detailStore.write(
        attachmentId: attachmentId,
        privacyClass: privacyClass,
        bytes: bytes,
        maxStoredBytes: effectiveMaxBytes,
        maxDuration: configuration.attachmentWriteTimeout,
        persistToText:
            session.detailStorage == DiagnosticDetailStorage.persistToText,
      );
      final descriptor = _descriptor(
        attachmentId: attachmentId,
        eventId: eventId,
        kind: kind,
        mediaType: mediaType,
        charset: charset,
        formatId: formatId,
        formatVersion: formatVersion,
        schemaId: schemaId,
        schemaVersion: schemaVersion,
        privacyClass: privacyClass,
        captureState: commit.captureState,
        rawByteLength: commit.rawByteLength,
        storedByteLength: commit.storedByteLength,
        sha256: commit.sha256,
        truncationReason: commit.truncationReason,
      );
      final stored = await _persistence.commitAttachment(
        descriptor: descriptor,
        objectKey: commit.detailKey.isEmpty ? null : commit.detailKey,
        persisted: commit.persisted,
      );
      _activeCapture = await _persistence.getCaptureSession(
        session.session.sessionId,
      );
      return stored;
    } catch (_) {
      final descriptor = _descriptor(
        attachmentId: attachmentId,
        eventId: eventId,
        kind: kind,
        mediaType: mediaType,
        charset: charset,
        formatId: formatId,
        formatVersion: formatVersion,
        schemaId: schemaId,
        schemaVersion: schemaVersion,
        privacyClass: privacyClass,
        captureState: DiagnosticCaptureState.failed,
        rawByteLength: 0,
        storedByteLength: 0,
        truncationReason: 'detailTextWriteFailed',
      );
      try {
        return await _persistence.commitAttachment(
          descriptor: descriptor,
          objectKey: null,
        );
      } catch (_) {
        return descriptor;
      }
    }
  }

  @override
  Future<DiagnosticMaintenanceResult> enforceRetention(
    DiagnosticRetentionPolicy policy,
  ) => manager.runSpan<DiagnosticMaintenanceResult>(
    AppDiagnosticEvents.retention,
    (_) async {
      await _sink.flush(timeout: configuration.defaultFlushTimeout);
      return _persistence.enforceRetention(policy);
    },
    successAttributes: (result) =>
        DiagnosticObjectValue(<String, DiagnosticValue>{
          'sessionCount': DiagnosticValue.int64(result.deletedSessions),
          'eventCount': DiagnosticValue.int64(result.deletedEvents),
          'reclaimedBytes': DiagnosticValue.int64(result.reclaimedBytes),
        }),
    errorAttributes: (_) => DiagnosticObjectValue(<String, DiagnosticValue>{
      'errorCode': DiagnosticValue.string('retention_failed'),
    }),
  );

  @override
  Future<void> deleteSession(String sessionId) async {
    await _persistence.deleteSession(sessionId);
  }

  @override
  Future<DiagnosticExportResult> exportBundle({
    required DiagnosticExportSelection selection,
    required DiagnosticExportPolicy policy,
  }) {
    throw UnsupportedError(
      'Bundle export is delivered with the diagnostics viewer package.',
    );
  }

  Future<DiagnosticStorageStatistics> getStatistics() async {
    await _sink.flush(timeout: configuration.defaultFlushTimeout);
    return _persistence.getStatistics();
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    if (_closed) return;
    _closing = true;
    _captureExpiryTimer?.cancel();
    if (_activeCapture case final capture?) {
      await _persistence.stopCaptureSession(capture.session.sessionId);
      _activeCapture = null;
      if (_captureSpan case final span? when !span.isEnded) {
        span.complete(
          attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
            'sessionState': DiagnosticValue.string('closed'),
          }),
        );
      }
      _captureSpan = null;
    }
    manager.emit(
      AppDiagnosticEvents.writerState,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'state': DiagnosticValue.string('stopping'),
        'queueDepth': DiagnosticValue.int64(_sink.statistics.queueDepth),
        'queueBytes': DiagnosticValue.int64(_sink.statistics.queueBytes),
        'batchSize': DiagnosticValue.int64(_sink.statistics.lastBatchSize),
        'commitMicros': DiagnosticValue.int64(
          _sink.statistics.lastCommitMicros,
        ),
      }),
    );
    try {
      await _attachmentWriteTail.timeout(
        configuration.attachmentWriteTimeout + const Duration(seconds: 1),
      );
    } on TimeoutException {
      // The object writer has its own deadline; shutdown stays fail-open.
    }
    _runSpan.complete();
    await manager.close(timeout: configuration.defaultFlushTimeout);
    await _persistence.endRun(sourceRunId);
    await _persistence.flushText();
    await _persistence.close();
    _closed = true;
  }

  String? _activeSessionForEvent(DiagnosticEvent event) {
    final capture = _activeCapture;
    if (capture == null ||
        capture.session.state != DiagnosticSessionState.active ||
        capture.remainingBytes <= 0) {
      return null;
    }
    if (capture.components.isNotEmpty &&
        !capture.components.contains(event.component)) {
      return null;
    }
    if (capture.origins.isNotEmpty) {
      final origin = event.attributes.values['origin'];
      if (origin is! DiagnosticStringValue ||
          !capture.origins.contains(origin.value)) {
        return null;
      }
    }
    return capture.session.sessionId;
  }

  bool _isCaptureEnabledForComponent(String component) {
    final capture = _activeCapture;
    if (capture == null ||
        capture.session.state != DiagnosticSessionState.active ||
        capture.remainingBytes <= 0) {
      return false;
    }
    return capture.components.isEmpty || capture.components.contains(component);
  }

  void _reportDrops(int count, int windowMicros, String reason) {
    manager.emit(
      AppDiagnosticEvents.eventsDropped,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'reason': DiagnosticValue.string(reason),
        'dropCount': DiagnosticValue.int64(count),
        'windowMicros': DiagnosticValue.int64(windowMicros),
        'lowestSeverity': DiagnosticValue.string('trace'),
      }),
    );
  }

  DiagnosticAttachmentDescriptor _descriptor({
    required String attachmentId,
    required String eventId,
    required String kind,
    required String mediaType,
    required String formatId,
    required int formatVersion,
    required DiagnosticPrivacyClass privacyClass,
    required DiagnosticCaptureState captureState,
    required int rawByteLength,
    required int storedByteLength,
    String? charset,
    String? schemaId,
    int? schemaVersion,
    String? sha256,
    String? truncationReason,
  }) => DiagnosticAttachmentDescriptor(
    attachmentId: attachmentId,
    eventId: eventId,
    kind: kind,
    mediaType: mediaType,
    charset: charset,
    formatId: formatId,
    formatVersion: formatVersion,
    schemaId: schemaId,
    schemaVersion: schemaVersion,
    privacyClass: privacyClass,
    captureState: captureState,
    rawByteLength: rawByteLength,
    storedByteLength: storedByteLength,
    sha256: sha256,
    storageCodec: DiagnosticStorageCodec.identity,
    redactionVersion: 1,
    truncationReason: truncationReason,
  );

  void _ensureOpen() {
    if (_closing || _closed) {
      throw StateError('AppDiagnosticsService is closing or closed.');
    }
  }
}

DiagnosticObjectValue _captureAttributes(
  DiagnosticCapturePolicy policy, {
  required String sessionState,
  String? errorCode,
}) => DiagnosticObjectValue(<String, DiagnosticValue>{
  'payloadKind': DiagnosticValue.string(policy.payloadKind.name),
  'durationMicros': DiagnosticValue.int64(policy.duration.inMicroseconds),
  'maxBytes': DiagnosticValue.int64(policy.maxStoredBytes),
  'detailStorage': DiagnosticValue.string(policy.detailStorage.name),
  'componentCount': DiagnosticValue.int64(policy.components.length),
  'originCount': DiagnosticValue.int64(policy.origins.length),
  'sessionState': DiagnosticValue.string(sessionState),
  if (errorCode != null) 'errorCode': DiagnosticValue.string(errorCode),
});

String _captureErrorCode(Object error) => switch (error) {
  UnsupportedError() => 'capture_mode_unsupported',
  RangeError() => 'capture_quota_invalid',
  StateError() => 'capture_state_invalid',
  _ => 'capture_start_failed',
};

bool _isTextDiagnosticMediaType(String mediaType) {
  final normalized = mediaType.split(';').first.trim().toLowerCase();
  return normalized.startsWith('text/') ||
      normalized == 'application/json' ||
      normalized.endsWith('+json') ||
      normalized == 'application/xml' ||
      normalized.endsWith('+xml') ||
      normalized == 'application/x-www-form-urlencoded' ||
      normalized == 'application/javascript';
}

bool _isStructuredDiagnosticMediaType(String mediaType) {
  final normalized = mediaType.split(';').first.trim().toLowerCase();
  return normalized == 'application/json' || normalized.endsWith('+json');
}
