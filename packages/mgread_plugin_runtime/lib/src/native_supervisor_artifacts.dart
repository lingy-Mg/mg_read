part of mgread_plugin_runtime;

/// Owns bounded native package export and import transfer operations.
final class _NativeRuntimeArtifactTransfer {
  _NativeRuntimeArtifactTransfer(this._supervisor);

  final _NativeRuntimeSupervisor _supervisor;

  Future<Stream<List<int>>> exportPluginArtifact(
    PluginTransferArtifact artifact,
  ) async {
    final materialized = await materializePluginArtifact(
      PluginTransferOffer(
        engine: PluginEngine.native,
        developmentFingerprint: artifact.developmentFingerprint,
        developmentRevision: artifact.developmentRevision,
        format: artifact.format,
        pluginId: artifact.pluginId,
        provenance: artifact.provenance,
        version: artifact.version,
      ),
    );
    if (materialized.artifact.bytes != artifact.bytes ||
        materialized.artifact.checksum != artifact.checksum ||
        materialized.artifact.version != artifact.version ||
        materialized.artifact.format != artifact.format ||
        materialized.artifact.provenance != artifact.provenance) {
      throw const PluginRuntimeException(
        'plugin_transfer_checksum_mismatch',
        'The native Runtime transfer artifact identity did not match the request.',
      );
    }
    return materialized.bytes;
  }

  Future<MaterializedPluginArtifact> materializePluginArtifact(
    PluginTransferOffer offer,
  ) async {
    _supervisor._assertOpen();
    if (offer.provenance != PluginArtifactProvenance.installed ||
        offer.format != PluginArtifactFormat.archive ||
        offer.developmentFingerprint != null ||
        offer.developmentRevision != null) {
      throw _supervisor._unsupported(
        'The native Runtime can transfer installed .mgplugin archives only.',
      );
    }
    final lease = await _supervisor._acquireInvocationLease();
    late final Object? raw;
    try {
      raw = await _supervisor._invokeRpc(
        method: 'plugins.native.export.v1',
        params: <String, Object?>{'pluginId': offer.pluginId},
        timeout: const Duration(minutes: 2),
      );
    } finally {
      lease.release();
    }
    final result = _nativeObject(raw, 'Native plugin export result');
    final encoded = result['base64'];
    final checksum = result['checksum'];
    final byteCount = result['bytes'];
    final version = result['version'];
    if (encoded is! String ||
        checksum is! String ||
        !RegExp(r'^[a-f0-9]{8}$').hasMatch(checksum) ||
        byteCount is! int ||
        byteCount <= 0 ||
        byteCount > maxPluginTransferBytes ||
        version is! String ||
        version != offer.version ||
        encoded.length > ((maxPluginTransferBytes + 2) ~/ 3) * 4) {
      throw const PluginRuntimeException(
        'plugin_transfer_checksum_mismatch',
        'The native Runtime returned invalid plugin export metadata.',
      );
    }
    late final List<int> bytes;
    try {
      bytes = base64Decode(encoded);
    } on FormatException {
      throw const PluginRuntimeException(
        'plugin_transfer_checksum_mismatch',
        'The native Runtime returned invalid plugin export bytes.',
      );
    }
    if (bytes.length != byteCount || _nativeCrc32(bytes) != checksum) {
      throw const PluginRuntimeException(
        'plugin_transfer_checksum_mismatch',
        'The native Runtime plugin export failed its integrity check.',
      );
    }
    final artifact = PluginTransferArtifact(
      engine: PluginEngine.native,
      bytes: byteCount,
      developmentFingerprint: null,
      developmentRevision: null,
      format: PluginArtifactFormat.archive,
      pluginId: offer.pluginId,
      provenance: PluginArtifactProvenance.installed,
      checksum: checksum,
      version: version,
    );
    return MaterializedPluginArtifact(
      artifact: artifact,
      bytes: _nativeByteStream(bytes),
    );
  }

  Future<PluginDevelopmentPackage> packageDevelopmentPlugin(
    String pluginId,
    String directoryPath,
  ) => Future<PluginDevelopmentPackage>.error(
    _supervisor._unsupported(
      'Native source development packaging is unavailable in this Runtime.',
    ),
  );

  Future<List<PluginTransferImportResult>> importPluginArtifacts(
    List<({PluginTransferArtifact artifact, Stream<List<int>> bytes})>
    artifacts, {
    Set<String> forceUpgradePluginIds = const <String>{},
  }) async {
    _supervisor._assertOpen();
    if (artifacts.isEmpty) {
      throw const PluginRuntimeException(
        'plugin_transfer_batch_too_large',
        'The native plugin transfer batch is invalid.',
      );
    }
    var batchBytes = 0;
    final pluginIds = <String>{};
    for (final item in artifacts) {
      final artifact = item.artifact;
      if (!pluginIds.add(artifact.pluginId)) {
        throw const PluginRuntimeException(
          'invalid_request',
          'A native transfer batch cannot contain the same source twice.',
        );
      }
      if (artifact.bytes <= 0 ||
          artifact.bytes > maxPluginTransferBytes ||
          artifact.format != PluginArtifactFormat.archive ||
          artifact.provenance != PluginArtifactProvenance.installed ||
          artifact.developmentFingerprint != null ||
          artifact.developmentRevision != null) {
        throw _supervisor._unsupported(
          'The native Runtime can import installed .mgplugin archives only.',
        );
      }
      batchBytes += artifact.bytes;
      if (batchBytes > maxPluginTransferBatchBytes) {
        throw const PluginRuntimeException(
          'plugin_transfer_batch_too_large',
          'The native plugin transfer batch is too large.',
        );
      }
    }
    final planInvocation = PluginTransferPlanInvocation(
      artifacts: artifacts.map((item) => item.artifact).toList(growable: false),
      forceUpgradePluginIds: forceUpgradePluginIds,
    );
    return _supervisor._runLifecycleTransition<
      List<PluginTransferImportResult>
    >(() async {
      final plan = planInvocation._decodeResult(
        await _supervisor._invokeRpc(
          method: planInvocation._wireMethod,
          params: planInvocation._wireParams,
          timeout: const Duration(minutes: 2),
        ),
      );
      if (plan.length != artifacts.length ||
          plan.any(
            (item) =>
                item.action != PluginTransferPlanAction.missing &&
                item.action != PluginTransferPlanAction.upgrade,
          ) ||
          List<int>.generate(artifacts.length, (index) => index).any(
            (index) =>
                plan[index].pluginId != artifacts[index].artifact.pluginId ||
                plan[index].version != artifacts[index].artifact.version,
          )) {
        throw const PluginRuntimeException(
          'invalid_request',
          'The native transfer would replace an equal or newer source.',
        );
      }
      final imported = <PluginTransferImportResult>[];
      var importSucceeded = false;
      var restartAttempted = false;
      try {
        for (var index = 0; index < artifacts.length; index += 1) {
          final item = artifacts[index];
          final artifact = item.artifact;
          final bytes = await _readNativeTransferBytes(
            item.bytes,
            artifact.bytes,
          );
          if (_nativeCrc32(bytes) != artifact.checksum) {
            throw const PluginRuntimeException(
              'plugin_transfer_checksum_mismatch',
              'The native transfer artifact failed its integrity check.',
            );
          }
          final raw = await _supervisor._invokeRpc(
            method: 'plugins.native.importBytes.v1',
            params: <String, Object?>{
              'name': '${artifact.pluginId}-${artifact.version}.mgplugin',
              'expectedPluginId': artifact.pluginId,
              'expectedVersion': artifact.version,
              'base64': base64Encode(bytes),
            },
            timeout: const Duration(minutes: 2),
          );
          importSucceeded = true;
          final result = _nativeObject(raw, 'Native plugin import result');
          validateNativeImportResult(result);
          if (result['pluginId'] != artifact.pluginId ||
              result['version'] != artifact.version) {
            throw const PluginRuntimeException(
              'plugin_transfer_checksum_mismatch',
              'The native Runtime installed a different transfer artifact.',
            );
          }
          imported.add(
            PluginTransferImportResult(
              pluginId: artifact.pluginId,
              status: PluginTransferImportStatus.installed,
              version: artifact.version,
            ),
          );
        }
        restartAttempted = true;
        await _supervisor._restartAfterManagementChange();
        return List<PluginTransferImportResult>.unmodifiable(imported);
      } on Object catch (error, stackTrace) {
        if (importSucceeded && !restartAttempted) {
          restartAttempted = true;
          try {
            await _supervisor._restartAfterManagementChange();
          } on Object catch (restartError) {
            _supervisor._record(
              RuntimeDiagnostic(
                code: restartError is PluginRuntimeException
                    ? restartError.code
                    : 'native_partial_import_restart_failed',
                level: RuntimeDiagnosticLevel.fatal,
                message:
                    'The native Runtime could not restart after a partial plugin transfer import.',
              ),
            );
            if (error is PluginRuntimeException) {
              Error.throwWithStackTrace(
                PluginRuntimeException(
                  error.code,
                  error.message,
                  diagnostics: _supervisor.latestDiagnostics,
                ),
                stackTrace,
              );
            }
          }
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
    });
  }

  void validateNativeImportResult(Object? raw) {
    final result = _nativeObject(raw, 'Native plugin import result');
    if (result['pluginId'] is! String ||
        result['version'] is! String ||
        result['restartRequired'] is! bool) {
      throw const PluginRuntimeException(
        'invalid_response',
        'The native Runtime returned an invalid plugin import result.',
      );
    }
  }

  Future<List<int>> _readNativeTransferBytes(
    Stream<List<int>> source,
    int expectedBytes,
  ) async {
    final bytes = <int>[];
    var received = 0;
    await for (final chunk in source) {
      received += chunk.length;
      if (received > expectedBytes || received > maxPluginTransferBytes) {
        throw const PluginRuntimeException(
          'plugin_transfer_size_mismatch',
          'The native transfer artifact exceeded its declared size.',
        );
      }
      bytes.addAll(chunk);
    }
    if (received != expectedBytes) {
      throw const PluginRuntimeException(
        'plugin_transfer_size_mismatch',
        'The native transfer artifact was truncated.',
      );
    }
    return bytes;
  }
}
