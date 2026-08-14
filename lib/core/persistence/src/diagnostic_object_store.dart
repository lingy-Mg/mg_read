import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:mg_read/core/diagnostics/src/diagnostic_event.dart';
import 'package:mg_read/core/diagnostics/src/diagnostic_ports.dart';

import 'diagnostic_sha256.dart';

final class DiagnosticObjectCommit {
  const DiagnosticObjectCommit({
    required this.objectKey,
    required this.sha256,
    required this.rawByteLength,
    required this.storedByteLength,
    required this.captureState,
    this.truncationReason,
  });

  final String objectKey;
  final String sha256;
  final int rawByteLength;
  final int storedByteLength;
  final DiagnosticCaptureState captureState;
  final String? truncationReason;
}

/// Immutable, content-addressed object storage below the app diagnostics root.
final class DiagnosticObjectStore {
  DiagnosticObjectStore._(
    this.root,
    this.objectsRoot,
    this.stagingRoot,
    this.exportsRoot,
  );

  final Directory root;
  final Directory objectsRoot;
  final Directory stagingRoot;
  final Directory exportsRoot;
  final Map<String, int> _leases = <String, int>{};
  bool _closed = false;

  static Future<DiagnosticObjectStore> open(Directory diagnosticsRoot) async {
    final objects = Directory(
      '${diagnosticsRoot.path}${Platform.pathSeparator}objects',
    );
    final staging = Directory(
      '${diagnosticsRoot.path}${Platform.pathSeparator}staging',
    );
    final exports = Directory(
      '${diagnosticsRoot.path}${Platform.pathSeparator}exports',
    );
    await Future.wait(<Future<void>>[
      diagnosticsRoot.create(recursive: true),
      objects.create(recursive: true),
      staging.create(recursive: true),
      exports.create(recursive: true),
    ]);
    final store = DiagnosticObjectStore._(
      diagnosticsRoot,
      objects,
      staging,
      exports,
    );
    await store.cleanStaging();
    return store;
  }

  Future<DiagnosticObjectCommit> write({
    required String attachmentId,
    required DiagnosticPrivacyClass privacyClass,
    required Stream<List<int>> bytes,
    required int maxStoredBytes,
    required Duration maxDuration,
  }) async {
    _ensureOpen();
    validateDiagnosticOpaqueId(attachmentId, 'attachmentId');
    if (privacyClass == DiagnosticPrivacyClass.secret) {
      throw ArgumentError('Secret diagnostic objects are never persisted.');
    }
    if (maxStoredBytes <= 0) {
      throw ArgumentError.value(maxStoredBytes, 'maxStoredBytes');
    }
    if (maxDuration <= Duration.zero) {
      throw ArgumentError.value(maxDuration, 'maxDuration');
    }
    final stagingFile = File(
      '${stagingRoot.path}${Platform.pathSeparator}$attachmentId.part',
    );
    RandomAccessFile? output;
    var rawByteLength = 0;
    var storedByteLength = 0;
    var truncated = false;
    String? truncationReason;
    final deadline = Stopwatch()..start();
    final iterator = StreamIterator<List<int>>(bytes);
    try {
      output = await stagingFile.open(mode: FileMode.writeOnly);
      while (true) {
        final remainingDuration = maxDuration - deadline.elapsed;
        if (remainingDuration <= Duration.zero) {
          truncated = true;
          truncationReason = 'attachmentWriteDeadline';
          break;
        }
        bool hasNext;
        try {
          hasNext = await iterator.moveNext().timeout(remainingDuration);
        } on TimeoutException {
          truncated = true;
          truncationReason = 'attachmentWriteDeadline';
          break;
        }
        if (!hasNext) break;
        final chunk = iterator.current;
        rawByteLength += chunk.length;
        final remaining = maxStoredBytes - storedByteLength;
        if (remaining <= 0) {
          truncated = true;
          truncationReason ??= 'singleAttachmentByteLimit';
          continue;
        }
        final acceptedLength = chunk.length < remaining
            ? chunk.length
            : remaining;
        if (acceptedLength > 0) {
          await output.writeFrom(chunk, 0, acceptedLength);
          storedByteLength += acceptedLength;
        }
        if (acceptedLength != chunk.length) {
          truncated = true;
          truncationReason ??= 'singleAttachmentByteLimit';
        }
      }
      await iterator.cancel();
      await output.flush();
      await output.close();
      output = null;
      final sha256 = await Isolate.run(
        _DiagnosticFileHashTask(stagingFile.path).call,
        debugName: 'mg-read-diagnostics-sha256',
      );
      final objectKey = _objectKey(privacyClass, sha256);
      final target = _fileForKey(objectKey);
      await target.parent.create(recursive: true);
      if (await target.exists()) {
        await stagingFile.delete();
      } else {
        await stagingFile.rename(target.path);
      }
      return DiagnosticObjectCommit(
        objectKey: objectKey,
        sha256: sha256,
        rawByteLength: rawByteLength,
        storedByteLength: storedByteLength,
        captureState: truncated
            ? DiagnosticCaptureState.truncated
            : DiagnosticCaptureState.captured,
        truncationReason: truncationReason,
      );
    } catch (_) {
      await iterator.cancel().catchError((_) {});
      if (output != null) {
        await output.close().catchError((_) {});
      }
      if (await stagingFile.exists()) {
        try {
          await stagingFile.delete();
        } catch (_) {
          // The original write failure remains authoritative.
        }
      }
      rethrow;
    }
  }

  Stream<List<int>> openObject(
    String objectKey, {
    DiagnosticByteRange? range,
  }) async* {
    _ensureOpen();
    final file = _fileForKey(objectKey);
    final length = await file.length();
    final start = range?.offset ?? 0;
    if (start > length) {
      throw RangeError.range(start, 0, length, 'range.offset');
    }
    final end = range == null
        ? length
        : (start + range.length < length ? start + range.length : length);
    _leases[objectKey] = (_leases[objectKey] ?? 0) + 1;
    try {
      yield* file.openRead(start, end);
    } finally {
      final remaining = (_leases[objectKey] ?? 1) - 1;
      if (remaining <= 0) {
        _leases.remove(objectKey);
      } else {
        _leases[objectKey] = remaining;
      }
    }
  }

  Future<bool> delete(String objectKey) async {
    _ensureOpen();
    if ((_leases[objectKey] ?? 0) > 0) return false;
    final file = _fileForKey(objectKey);
    if (await file.exists()) await file.delete();
    await _deleteEmptyParents(file.parent);
    return true;
  }

  Future<void> cleanStaging() async {
    _ensureOpen();
    if (!await stagingRoot.exists()) return;
    await for (final entity in stagingRoot.list(followLinks: false)) {
      if (entity is File) {
        await entity.delete();
      } else if (entity is Directory) {
        await entity.delete(recursive: true);
      }
    }
  }

  Future<Set<String>> listObjectKeys() async {
    _ensureOpen();
    final result = <String>{};
    if (!await objectsRoot.exists()) return result;
    await for (final entity in objectsRoot.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final relative = _relativePath(entity.path, objectsRoot.path);
      if (_validObjectKey.hasMatch(relative)) result.add(relative);
    }
    return result;
  }

  File createExportStagingFile(String exportId) {
    _ensureOpen();
    validateDiagnosticOpaqueId(exportId, 'exportId');
    return File(
      '${stagingRoot.path}${Platform.pathSeparator}$exportId.export.part',
    );
  }

  Future<String> commitExport(File stagingFile, String exportId) async {
    _ensureOpen();
    validateDiagnosticOpaqueId(exportId, 'exportId');
    final relative = 'exports/$exportId.mgdiag.tar';
    final target = File(
      '${root.path}${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}',
    );
    if (await target.exists()) await target.delete();
    await stagingFile.rename(target.path);
    return relative;
  }

  Future<void> close() async {
    _closed = true;
  }

  File _fileForKey(String objectKey) {
    if (!_validObjectKey.hasMatch(objectKey)) {
      throw ArgumentError.value(objectKey, 'objectKey');
    }
    final platformKey = objectKey.replaceAll('/', Platform.pathSeparator);
    return File('${objectsRoot.path}${Platform.pathSeparator}$platformKey');
  }

  String _objectKey(DiagnosticPrivacyClass privacyClass, String sha256) =>
      '${privacyClass.name}/${sha256.substring(0, 2)}/${sha256.substring(2, 4)}/$sha256';

  String _relativePath(String path, String parent) {
    final prefix = parent.endsWith(Platform.pathSeparator)
        ? parent
        : '$parent${Platform.pathSeparator}';
    if (!path.startsWith(prefix)) throw StateError('Object escaped its root.');
    return path
        .substring(prefix.length)
        .replaceAll(Platform.pathSeparator, '/');
  }

  Future<void> _deleteEmptyParents(Directory directory) async {
    var current = directory;
    while (current.path != objectsRoot.path &&
        current.path.startsWith(objectsRoot.path)) {
      if (!await current.exists() || !await current.list().isEmpty) return;
      await current.delete();
      current = current.parent;
    }
  }

  void _ensureOpen() {
    if (_closed) throw StateError('DiagnosticObjectStore is closed.');
  }
}

final RegExp _validObjectKey = RegExp(
  r'^(public|internal|content|restricted)/[a-f0-9]{2}/[a-f0-9]{2}/[a-f0-9]{64}$',
);

String _sha256File(String path) {
  final digest = DiagnosticSha256();
  final input = File(path).openSync();
  try {
    while (true) {
      final chunk = input.readSync(64 * 1024);
      if (chunk.isEmpty) break;
      digest.add(chunk);
    }
  } finally {
    input.closeSync();
  }
  return digest.closeHex();
}

final class _DiagnosticFileHashTask {
  const _DiagnosticFileHashTask(this.path);

  final String path;

  String call() => _sha256File(path);
}
