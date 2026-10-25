part of mgread_plugin_runtime;

/// Owns desktop plugin-artifact picker handoff, development packaging and
/// path-free transfer IO. Import-triggered restarts are delegated to the
/// supervisor so lifecycle admission stays centralized.
final class _DesktopPluginArtifactIo {
  _DesktopPluginArtifactIo(this._supervisor);

  final _DesktopRuntimeSupervisor _supervisor;

  Future<Stream<List<int>>> exportArtifact(
    PluginTransferArtifact artifact,
  ) async {
    final materialized = await materializeArtifact(_offerFrom(artifact));
    final returned = materialized.artifact;
    if (returned.bytes != artifact.bytes ||
        returned.checksum != artifact.checksum) {
      throw const PluginRuntimeException(
        'plugin_transfer_checksum_mismatch',
        'The Runtime transfer artifact identity did not match the request.',
      );
    }
    return materialized.bytes;
  }

  Future<MaterializedPluginArtifact> materializeArtifact(
    PluginTransferOffer offer,
  ) async {
    _assertOpen();
    final connection = await _supervisor._ensureStarted();
    final raw = await connection.request(
      method: 'plugins.transfer.export.v2',
      params: <String, Object?>{'id': offer.pluginId, 'version': offer.version},
      timeout: const Duration(minutes: 2),
    );
    final result = _jsonObject(raw, 'Plugin transfer export result');
    final token = result['token'];
    final returned = _decodePluginTransferArtifact(result);
    if (token is! String ||
        returned.pluginId != offer.pluginId ||
        returned.version != offer.version ||
        returned.format != offer.format ||
        returned.provenance != offer.provenance ||
        returned.developmentFingerprint != offer.developmentFingerprint ||
        returned.developmentRevision != offer.developmentRevision) {
      throw const PluginRuntimeException(
        'plugin_transfer_checksum_mismatch',
        'The Runtime transfer artifact identity did not match the request.',
      );
    }
    return MaterializedPluginArtifact(
      artifact: returned,
      bytes: await connection.readTransferResource(
        expectedBytes: returned.bytes,
        token: token,
      ),
    );
  }

  PluginTransferOffer _offerFrom(PluginTransferArtifact artifact) =>
      PluginTransferOffer(
        developmentFingerprint: artifact.developmentFingerprint,
        developmentRevision: artifact.developmentRevision,
        format: artifact.format,
        pluginId: artifact.pluginId,
        provenance: artifact.provenance,
        version: artifact.version,
      );

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

  late final _store = _PluginImportDirectoryStore(_inbox());
  late final _artifactImporter = _PluginArtifactImporter(
    assertOpen: _assertOpen,
    plan: (artifacts, force) => _supervisor.invoke(
      PluginTransferPlanInvocation(
        artifacts: artifacts,
        forceUpgradePluginIds: force,
      ),
    ),
    begin: _store.begin,
    verify: (batch, artifacts) =>
        _supervisor.invoke(_VerifyPluginImportInvocation(batch.id, artifacts)),
    publishAndRestart: (batch) async {
      await _store.publish(batch);
      await _supervisor._restartForPluginImport();
    },
    cancel: _store.cancel,
    installed: () => _supervisor.invoke(const InstalledPluginsInvocation()),
  );

  Future<List<PluginTransferImportResult>> importArtifacts(
    List<_PluginArtifactInput> artifacts, {
    Set<String> forceUpgradePluginIds = const {},
  }) => _artifactImporter.importArtifacts(
    artifacts,
    forceUpgradePluginIds: forceUpgradePluginIds,
  );

  Future<void> importLocalArtifact(String sourcePath) =>
      _artifactImporter.exclusive(() => _importLocalArtifact(sourcePath));

  Future<void> _importLocalArtifact(String sourcePath) async {
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

  Future<void> _copyStream(
    Stream<List<int>> source,
    File temporary,
    int expectedBytes,
  ) => _writePluginArtifactFile(source, temporary, expectedBytes);
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
