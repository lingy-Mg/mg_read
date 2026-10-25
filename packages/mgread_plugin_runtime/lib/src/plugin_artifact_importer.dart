part of mgread_plugin_runtime;

/// Shared Node import transaction for desktop, Javet and Android Node service.
/// Owns admission from planning through catalog confirmation, bounded file IO,
/// manifests and cleanup. Hosts own private staging roots and restart mechanics.
typedef _PluginArtifactInput = ({
  PluginTransferArtifact artifact,
  Stream<List<int>> bytes,
});

final class _PluginImportBatch {
  _PluginImportBatch(this.id, this.directory, this.temporaryPaths);
  final String id;
  final Directory directory;
  final List<String> temporaryPaths;

  Map<String, Object?> manifest(List<_PluginArtifactInput> inputs) => {
    'schemaVersion': 1,
    'artifacts': [
      for (var index = 0; index < inputs.length; index++)
        {
          ...inputs[index].artifact.toJson(),
          'file': '$index${_suffix(inputs[index].artifact.format)}',
        },
    ],
  };
}

final class _VerifyPluginImportInvocation extends PluginInvocation<void> {
  const _VerifyPluginImportInvocation(this.batchId, this.artifacts);
  final String batchId;
  final List<PluginTransferArtifact> artifacts;
  @override
  String get _wireMethod => 'plugins.transfer.verify.v2';
  @override
  Duration get _timeout => const Duration(minutes: 2);
  @override
  Map<String, Object?> get _wireParams => {
    'batchId': batchId,
    'artifacts': artifacts.map((item) => item.toJson()).toList(),
  };
  @override
  void _decodeResult(Object? value) {
    if (value is! Map<Object?, Object?> || value['verified'] != true) {
      throw const PluginRuntimeException(
        'invalid_response',
        'The Runtime did not verify the import batch.',
      );
    }
  }
}

final class _PluginArtifactImporter {
  _PluginArtifactImporter({
    required this.plan,
    required this.begin,
    required this.verify,
    required this.publishAndRestart,
    required this.cancel,
    required this.installed,
    required this.assertOpen,
  });

  final Future<List<PluginTransferPlanItem>> Function(
    List<PluginTransferArtifact>,
    Set<String>,
  )
  plan;
  final Future<_PluginImportBatch> Function(List<PluginTransferArtifact>) begin;
  final Future<void> Function(_PluginImportBatch, List<PluginTransferArtifact>)
  verify;
  final Future<void> Function(_PluginImportBatch) publishAndRestart;
  final Future<void> Function(_PluginImportBatch) cancel;
  final Future<List<InstalledPlugin>> Function() installed;
  final void Function() assertOpen;
  Future<void> _tail = Future<void>.value();

  Future<T> exclusive<T>(Future<T> Function() operation) {
    final result = _tail.then((_) {
      assertOpen();
      return operation();
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<List<PluginTransferImportResult>> importArtifacts(
    List<_PluginArtifactInput> inputs, {
    Set<String> forceUpgradePluginIds = const {},
  }) => exclusive(() async {
    _validatePluginImportBatch(inputs);
    final artifacts = [for (final input in inputs) input.artifact];
    final decisions = await plan(artifacts, forceUpgradePluginIds);
    if (decisions.length != artifacts.length ||
        decisions.any(
          (item) =>
              item.action != PluginTransferPlanAction.missing &&
              item.action != PluginTransferPlanAction.upgrade,
        )) {
      throw const PluginRuntimeException(
        'invalid_request',
        'The plugin import plan rejected an artifact.',
      );
    }
    _PluginImportBatch? batch;
    try {
      batch = await begin(artifacts);
      if (batch.temporaryPaths.length != inputs.length) {
        throw const PluginRuntimeException(
          'invalid_response',
          'The plugin import staging batch is invalid.',
        );
      }
      for (var index = 0; index < inputs.length; index++) {
        assertOpen();
        await _writePluginArtifactFile(
          inputs[index].bytes,
          File(batch.temporaryPaths[index]),
          inputs[index].artifact.bytes,
        );
      }
      await File(
        _joinPath([batch.directory.path, 'manifest.json']),
      ).writeAsString(jsonEncode(batch.manifest(inputs)), flush: true);
      assertOpen();
      await verify(batch, artifacts);
      assertOpen();
      await publishAndRestart(batch);
      return _pluginImportResults(artifacts, await installed());
    } on PlatformException catch (error) {
      throw PluginRuntimeException(
        error.code,
        'The Runtime could not import the plugin batch.',
      );
    } on FileSystemException catch (error) {
      throw _pluginImportFileError(error);
    } finally {
      if (batch != null) {
        try {
          await cancel(batch);
        } on Object {
          /* Preserve the transaction result. */
        }
      }
    }
  });
}

void _validatePluginImportBatch(List<_PluginArtifactInput> inputs) {
  if (inputs.isEmpty) {
    throw const PluginRuntimeException(
      'plugin_transfer_batch_too_large',
      'The plugin import batch is empty.',
    );
  }
  var total = 0;
  final ids = <String>{};
  for (final input in inputs) {
    final artifact = input.artifact;
    if (!ids.add(artifact.pluginId)) {
      throw const PluginRuntimeException(
        'invalid_request',
        'A plugin import batch cannot contain duplicate sources.',
      );
    }
    if (artifact.bytes <= 0 || artifact.bytes > maxPluginTransferBytes) {
      throw const PluginRuntimeException(
        'plugin_transfer_artifact_too_large',
        'The plugin artifact is too large.',
      );
    }
    total += artifact.bytes;
    if (total > maxPluginTransferBatchBytes) {
      throw const PluginRuntimeException(
        'plugin_transfer_batch_too_large',
        'The plugin import batch is too large.',
      );
    }
  }
}

/// Await each bounded disk write: no IOSink error future or unbounded buffering.
Future<void> _writePluginArtifactFile(
  Stream<List<int>> source,
  File temporary,
  int expectedBytes,
) async {
  final output = await temporary.open(mode: FileMode.write);
  var copied = 0;
  try {
    await for (final chunk in source) {
      copied += chunk.length;
      if (copied > expectedBytes || copied > maxPluginTransferBytes) {
        throw const PluginRuntimeException(
          'plugin_transfer_size_mismatch',
          'The plugin artifact exceeded its declared size.',
        );
      }
      for (var offset = 0; offset < chunk.length; offset += 64 * 1024) {
        await output.writeFrom(
          chunk,
          offset,
          min(offset + 64 * 1024, chunk.length),
        );
      }
    }
    if (copied != expectedBytes) {
      throw const PluginRuntimeException(
        'plugin_transfer_size_mismatch',
        'The plugin artifact was truncated.',
      );
    }
    await output.flush();
  } catch (error, stack) {
    try {
      await output.close();
    } on Object {
      /* Preserve the original failure. */
    }
    Error.throwWithStackTrace(error, stack);
  }
  await output.close();
}

PluginRuntimeException _pluginImportFileError(FileSystemException error) =>
    PluginRuntimeException(
      const {28, 39, 112}.contains(error.osError?.errorCode)
          ? 'disk_full'
          : 'file_write_failed',
      'The plugin artifact could not be written to private storage.',
    );

/// Desktop adapter for the same directory/manifest contract owned by Kotlin on Android.
final class _PluginImportDirectoryStore {
  _PluginImportDirectoryStore(this.inbox);
  final Directory inbox;
  Future<void>? _prepared;

  Future<_PluginImportBatch> begin(
    List<PluginTransferArtifact> artifacts,
  ) async {
    try {
      await (_prepared ??= _prepare());
    } on Object {
      _prepared = null;
      rethrow;
    }
    final id = List.generate(
      16,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final directory = await Directory(
      _joinPath([inbox.path, '.batch-$id.part']),
    ).create();
    return _PluginImportBatch(id, directory, [
      for (var index = 0; index < artifacts.length; index++)
        _joinPath([
          directory.path,
          '$index${_suffix(artifacts[index].format)}.part',
        ]),
    ]);
  }

  Future<void> _prepare() async {
    await inbox.create(recursive: true);
    // Runs once per host, never during its Core restarts or active imports.
    await for (final entry in inbox.list(followLinks: false)) {
      final name = entry.uri.pathSegments.where((part) => part.isNotEmpty).last;
      if (RegExp(r'^\.batch-[a-f0-9]{32}\.part$').hasMatch(name) ||
          RegExp(
            r'^(?:transfer-|import-).+\.mgplugin(?:\.js)?\.part$',
          ).hasMatch(name)) {
        await entry.delete(recursive: entry is Directory);
      }
    }
  }

  Future<void> publish(_PluginImportBatch batch) async {
    for (final path in batch.temporaryPaths) {
      await File(path).rename(path.substring(0, path.length - '.part'.length));
    }
    await batch.directory.rename(_joinPath([inbox.path, 'batch-${batch.id}']));
  }

  Future<void> cancel(_PluginImportBatch batch) async {
    for (final directory in [
      batch.directory,
      Directory(_joinPath([inbox.path, 'batch-${batch.id}'])),
    ]) {
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  }
}

/// Both Android Node backends use this exact channel protocol and writer.
Future<_PluginImportBatch> _beginAndroidPluginImport(
  MethodChannel channel,
  List<PluginTransferArtifact> artifacts,
) async {
  final raw = await channel.invokeMapMethod<String, Object?>(
    'beginPluginTransferBatch',
    {'artifacts': artifacts.map((artifact) => artifact.toJson()).toList()},
  );
  final id = raw?['id'];
  final directory = raw?['directory'];
  final paths = raw?['temporaryPaths'];
  if (id is! String ||
      !RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ||
      directory is! String ||
      paths is! List<Object?> ||
      paths.any((path) => path is! String)) {
    throw const PluginRuntimeException(
      'invalid_response',
      'Android returned an invalid plugin staging batch.',
    );
  }
  return _PluginImportBatch(id, Directory(directory), paths.cast<String>());
}
