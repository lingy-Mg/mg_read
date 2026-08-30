part of mgread_plugin_runtime;

/// Owns desktop plugin-artifact picker handoff, development packaging and path-free transfer IO.
final class _DesktopPluginArtifactIo {
  _DesktopPluginArtifactIo(this._supervisor);

  final _DesktopRuntimeSupervisor _supervisor;

  Future<Stream<List<int>>> exportArtifact(
    PluginTransferArtifact artifact,
  ) async {
    _assertOpen();
    final connection = await _supervisor._ensureStarted();
    final raw = await connection.request(
      method: 'plugins.transfer.export.v2',
      params: <String, Object?>{
        'id': artifact.pluginId,
        'version': artifact.version,
      },
      timeout: const Duration(minutes: 2),
    );
    final result = _jsonObject(raw, 'Plugin transfer export result');
    final token = result['token'];
    final returned = _decodePluginTransferArtifact(result);
    if (token is! String ||
        returned.pluginId != artifact.pluginId ||
        returned.version != artifact.version ||
        returned.bytes != artifact.bytes ||
        returned.sha256 != artifact.sha256 ||
        returned.format != artifact.format) {
      throw const PluginRuntimeException(
        'plugin_transfer_checksum_mismatch',
        'The Runtime transfer artifact identity did not match the request.',
      );
    }
    return connection.readTransferResource(
      expectedBytes: returned.bytes,
      token: token,
    );
  }

  Future<PluginDevelopmentPackage> packageDevelopmentPlugin(
    String pluginId,
    Directory outputDirectory,
  ) async {
    _assertOpen();
    if (!await outputDirectory.exists()) {
      throw const PluginRuntimeException(
        'file_unavailable',
        'The selected output directory is unavailable.',
      );
    }
    final connection = await _supervisor._ensureStarted();
    final raw = await connection.request(
      method: 'plugins.development.package.v1',
      params: <String, Object?>{'pluginId': pluginId},
      timeout: const Duration(minutes: 2),
    );
    final result = _jsonObject(raw, 'Development plugin package result');
    final token = result['token'];
    final fileName = result['fileName'];
    final artifact = _decodePluginTransferArtifact(result);
    final expectedFileName =
        '${artifact.pluginId}-${artifact.version}${_suffix(artifact.format)}';
    if (token is! String ||
        fileName is! String ||
        fileName != expectedFileName) {
      throw const PluginRuntimeException(
        'invalid_response',
        'The Runtime returned an invalid development package result.',
      );
    }
    final target = File(_joinPath(<String>[outputDirectory.path, fileName]));
    if (await target.exists()) {
      throw const PluginRuntimeException(
        'file_already_exists',
        'A plugin artifact with this version already exists in the selected directory.',
      );
    }
    final temporary = File(
      '${target.path}.${DateTime.now().microsecondsSinceEpoch}.part',
    );
    try {
      await _copyStream(
        await connection.readTransferResource(
          expectedBytes: artifact.bytes,
          token: token,
        ),
        temporary,
        artifact.bytes,
      );
      await temporary.rename(target.path);
      return PluginDevelopmentPackage(artifact: artifact, fileName: fileName);
    } on PluginRuntimeException {
      rethrow;
    } on FileSystemException {
      throw const PluginRuntimeException(
        'file_write_failed',
        'The development plugin artifact could not be written.',
      );
    } finally {
      try {
        if (await temporary.exists()) await temporary.delete();
      } on FileSystemException {}
    }
  }

  Future<List<PluginTransferImportResult>> importArtifacts(
    List<({PluginTransferArtifact artifact, Stream<List<int>> bytes})>
    artifacts,
  ) async {
    _assertOpen();
    _validateBatch(artifacts);
    final inbox = _inbox();
    final connection = await _supervisor._ensureStarted();
    final planRaw = await connection.request(
      method: 'plugins.transfer.plan.v2',
      params: <String, Object?>{
        'artifacts': artifacts.map((item) => item.artifact.toJson()).toList(),
      },
      timeout: const Duration(minutes: 2),
    );
    final plan = PluginTransferPlanInvocation(
      artifacts: [for (final item in artifacts) item.artifact],
    )._decodeResult(planRaw);
    if (plan.any(
      (item) =>
          item.action == PluginTransferPlanAction.receiverNewer ||
          item.action == PluginTransferPlanAction.same ||
          item.action == PluginTransferPlanAction.unavailable,
    )) {
      throw const PluginRuntimeException(
        'invalid_request',
        'The plugin transfer would downgrade or replace an equal Runtime version.',
      );
    }
    await inbox.create(recursive: true);
    _supervisor._controlledRestarting = true;
    final temporaryFiles = <File>[];
    try {
      for (final item in artifacts) {
        final artifact = item.artifact;
        final stem =
            'transfer-${artifact.pluginId}-${artifact.version}-${DateTime.now().microsecondsSinceEpoch}';
        final target = File(
          _joinPath(<String>[inbox.path, '$stem${_suffix(artifact.format)}']),
        );
        final temporary = File('${target.path}.part');
        temporaryFiles.add(temporary);
        await _copyStream(item.bytes, temporary, artifact.bytes);
        await temporary.rename(target.path);
      }
      await connection.request(
        method: 'plugins.transfer.verify.v2',
        params: <String, Object?>{
          'artifacts': artifacts.map((item) => item.artifact.toJson()).toList(),
        },
        timeout: const Duration(minutes: 2),
      );
      await _supervisor._restartForPluginImport();
      await _supervisor._ensureStarted();
      return <PluginTransferImportResult>[
        for (final item in artifacts)
          PluginTransferImportResult(
            pluginId: item.artifact.pluginId,
            status: PluginTransferImportStatus.installed,
            version: item.artifact.version,
          ),
      ];
    } finally {
      _supervisor._controlledRestarting = false;
      for (final file in temporaryFiles) {
        try {
          if (await file.exists()) await file.delete();
        } on Object {}
      }
    }
  }

  Future<void> importLocalArtifact(String sourcePath) async {
    _assertOpen();
    final source = File(sourcePath);
    final format = _formatForPath(sourcePath);
    if (format == null) {
      throw const PluginRuntimeException(
        'file_name_invalid',
        'The selected file is not a MgRead plugin artifact.',
      );
    }
    if (!await source.exists()) {
      throw const PluginRuntimeException(
        'not_found',
        'The selected plugin artifact is unavailable.',
      );
    }
    final inbox = _inbox();
    await inbox.create(recursive: true);
    final target = File(
      _joinPath(<String>[
        inbox.path,
        'import-${DateTime.now().microsecondsSinceEpoch}${_suffix(format)}',
      ]),
    );
    final temporary = File('${target.path}.part');
    _supervisor._controlledRestarting = true;
    try {
      final totalBytes = await source.length();
      _supervisor._emitInitializationProgress(
        completedBytes: 0,
        stage: 'plugin_copying',
        totalBytes: totalBytes,
      );
      await source.copy(temporary.path);
      _supervisor._emitInitializationProgress(
        completedBytes: totalBytes,
        stage: 'plugin_copied',
        totalBytes: totalBytes,
      );
      await temporary.rename(target.path);
      _supervisor._emitInitializationProgress(
        completedBytes: 0,
        stage: 'plugin_installing',
        totalBytes: 0,
      );
      await _supervisor._restartForPluginImport();
      await _supervisor._ensureStarted();
      _supervisor._emitInitializationProgress(
        completedBytes: 1,
        stage: 'ready',
        totalBytes: 1,
      );
    } on FileSystemException {
      try {
        await temporary.delete();
      } on FileSystemException {}
      throw const PluginRuntimeException(
        'disk_full',
        'The selected plugin artifact could not be imported.',
      );
    } finally {
      _supervisor._controlledRestarting = false;
    }
  }

  void _assertOpen() {
    if (_supervisor._disposed) {
      throw const PluginRuntimeException(
        'runtime_unavailable',
        'The desktop Runtime has been closed.',
      );
    }
  }

  Directory _inbox() => Directory(
    _joinPath(<String>[_supervisor._bundle.dataRoot.path, 'import-inbox']),
  );

  void _validateBatch(
    List<({PluginTransferArtifact artifact, Stream<List<int>> bytes})>
    artifacts,
  ) {
    if (artifacts.isEmpty || artifacts.length > maxPluginTransferBatch) {
      throw const PluginRuntimeException(
        'plugin_transfer_batch_too_large',
        'The plugin transfer batch is invalid.',
      );
    }
    var total = 0;
    for (final item in artifacts) {
      if (item.artifact.bytes <= 0 ||
          item.artifact.bytes > maxPluginTransferBytes) {
        throw const PluginRuntimeException(
          'plugin_transfer_artifact_too_large',
          'The plugin transfer artifact is too large.',
        );
      }
      total += item.artifact.bytes;
      if (total > maxPluginTransferBatchBytes) {
        throw const PluginRuntimeException(
          'plugin_transfer_batch_too_large',
          'The plugin transfer batch is too large.',
        );
      }
    }
  }

  Future<void> _copyStream(
    Stream<List<int>> source,
    File temporary,
    int expectedBytes,
  ) async {
    var copied = 0;
    final sink = temporary.openWrite();
    try {
      await for (final chunk in source) {
        copied += chunk.length;
        if (copied > expectedBytes || copied > maxPluginTransferBytes) {
          throw const PluginRuntimeException(
            'plugin_transfer_size_mismatch',
            'The plugin transfer artifact exceeded its declared size.',
          );
        }
        sink.add(chunk);
      }
    } finally {
      await sink.close();
    }
    if (copied != expectedBytes) {
      throw const PluginRuntimeException(
        'plugin_transfer_size_mismatch',
        'The plugin transfer artifact was truncated.',
      );
    }
  }
}

PluginArtifactFormat? _formatForPath(String path) {
  final lowerPath = path.toLowerCase();
  if (lowerPath.endsWith('.mgplugin.js')) {
    return PluginArtifactFormat.singleFile;
  }
  if (lowerPath.endsWith('.mgplugin')) return PluginArtifactFormat.archive;
  return null;
}

String _suffix(PluginArtifactFormat format) => switch (format) {
  PluginArtifactFormat.singleFile => '.mgplugin.js',
  PluginArtifactFormat.archive => '.mgplugin',
};
