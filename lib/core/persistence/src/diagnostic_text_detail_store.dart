import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:mg_read/core/diagnostics/src/diagnostic_event.dart';
import 'package:mg_read/core/diagnostics/src/diagnostic_ports.dart';

import 'diagnostic_sha256.dart';

final class DiagnosticTextDetailCommit {
  const DiagnosticTextDetailCommit({
    required this.detailKey,
    required this.sha256,
    required this.rawByteLength,
    required this.storedByteLength,
    required this.captureState,
    required this.persisted,
    this.truncationReason,
  });

  final String detailKey;
  final String sha256;
  final int rawByteLength;
  final int storedByteLength;
  final DiagnosticCaptureState captureState;
  final bool persisted;
  final String? truncationReason;
}

final class DiagnosticTextDetailStatistics {
  const DiagnosticTextDetailStatistics({required this.detailCount, required this.detailTextBytes, required this.memoryDetailBytes});

  final int detailCount;
  final int detailTextBytes;
  final int memoryDetailBytes;
}

/// Bounded debug-detail spool with optional UTF-8 TXT persistence.
///
/// The caller must pass this store a stream only after the explicit capture
/// gate succeeds. Input is capped and stored byte-for-byte; it never becomes
/// an unbounded string in this layer.
final class DiagnosticTextDetailStore {
  DiagnosticTextDetailStore._(this.root, this.detailsRoot, this.stagingRoot, this.maxMemoryBytes);

  static const int defaultMaxMemoryBytes = 8 * 1024 * 1024;

  final Directory root;
  final Directory detailsRoot;
  final Directory stagingRoot;
  final int maxMemoryBytes;
  final Map<String, Uint8List> _memoryDetails = <String, Uint8List>{};
  final Map<String, int> _leases = <String, int>{};
  var _memoryBytes = 0;
  bool _closed = false;

  static Future<DiagnosticTextDetailStore> open(Directory diagnosticsRoot, {int maxMemoryBytes = defaultMaxMemoryBytes}) async {
    if (maxMemoryBytes <= 0) {
      throw ArgumentError.value(maxMemoryBytes, 'maxMemoryBytes');
    }
    final details = Directory('${diagnosticsRoot.path}${Platform.pathSeparator}details');
    final staging = Directory('${diagnosticsRoot.path}${Platform.pathSeparator}staging');
    await Future.wait(<Future<void>>[
      diagnosticsRoot.create(recursive: true),
      details.create(recursive: true),
      staging.create(recursive: true),
    ]);
    final store = DiagnosticTextDetailStore._(diagnosticsRoot, details, staging, maxMemoryBytes);
    await store.cleanStaging();
    return store;
  }

  Future<DiagnosticTextDetailCommit> write({
    required String attachmentId,
    required Stream<List<int>> bytes,
    required int maxStoredBytes,
    required Duration maxDuration,
    required bool persistToText,
  }) async {
    _ensureOpen();
    validateDiagnosticOpaqueId(attachmentId, 'attachmentId');
    if (maxStoredBytes <= 0 || maxDuration <= Duration.zero) {
      throw ArgumentError('Detail limits must be positive.');
    }

    final availableMemory = maxMemoryBytes - _memoryBytes;
    if (availableMemory <= 0) {
      return const DiagnosticTextDetailCommit(
        detailKey: '',
        sha256: '',
        rawByteLength: 0,
        storedByteLength: 0,
        captureState: DiagnosticCaptureState.pressureDropped,
        persisted: false,
        truncationReason: 'detailMemoryPressure',
      );
    }
    final acceptedBudget = min(maxStoredBytes, availableMemory);
    final collected = BytesBuilder(copy: false);
    var acceptedBytes = 0;
    var rawByteLength = 0;
    var truncated = false;
    String? truncationReason;
    final stopwatch = Stopwatch()..start();
    final iterator = StreamIterator<List<int>>(bytes);
    try {
      while (true) {
        final remainingTime = maxDuration - stopwatch.elapsed;
        if (remainingTime <= Duration.zero) {
          truncated = true;
          truncationReason = 'attachmentWriteDeadline';
          break;
        }
        bool hasNext;
        try {
          hasNext = await iterator.moveNext().timeout(remainingTime);
        } on TimeoutException {
          truncated = true;
          truncationReason = 'attachmentWriteDeadline';
          break;
        }
        if (!hasNext) break;
        final chunk = iterator.current;
        rawByteLength += chunk.length;
        final remaining = acceptedBudget - acceptedBytes;
        if (remaining <= 0) {
          truncated = true;
          truncationReason ??= acceptedBudget < maxStoredBytes ? 'detailMemoryPressure' : 'singleAttachmentByteLimit';
          continue;
        }
        final take = min(remaining, chunk.length);
        if (take > 0) {
          collected.add(take == chunk.length ? chunk : chunk.sublist(0, take));
          acceptedBytes += take;
        }
        if (take != chunk.length) {
          truncated = true;
          truncationReason ??= acceptedBudget < maxStoredBytes ? 'detailMemoryPressure' : 'singleAttachmentByteLimit';
        }
      }
    } finally {
      try {
        await iterator.cancel().timeout(const Duration(milliseconds: 100));
      } catch (_) {
        // A hostile/stalled source cannot hold diagnostics shutdown open.
      }
    }

    var stored = collected.takeBytes();
    if (stored.length > acceptedBudget) {
      stored = Uint8List.sublistView(stored, 0, acceptedBudget);
      truncated = true;
      truncationReason ??= 'singleAttachmentByteLimit';
    }
    final detailKey = attachmentId;
    if (persistToText) {
      await _commitTextFile(detailKey, stored);
    } else {
      final immutable = Uint8List.fromList(stored);
      _memoryDetails[detailKey] = immutable;
      _memoryBytes += immutable.length;
    }
    return DiagnosticTextDetailCommit(
      detailKey: detailKey,
      sha256: (DiagnosticSha256()..add(stored)).closeHex(),
      rawByteLength: rawByteLength,
      storedByteLength: stored.length,
      captureState: truncated ? DiagnosticCaptureState.truncated : DiagnosticCaptureState.captured,
      persisted: persistToText,
      truncationReason: truncationReason,
    );
  }

  Stream<List<int>> openDetail(String detailKey, {DiagnosticByteRange? range}) async* {
    _ensureOpen();
    validateDiagnosticOpaqueId(detailKey, 'detailKey');
    final memory = _memoryDetails[detailKey];
    if (memory != null) {
      final start = range?.offset ?? 0;
      if (start > memory.length) {
        throw RangeError.range(start, 0, memory.length, 'range.offset');
      }
      final end = range == null ? memory.length : min(memory.length, start + range.length);
      yield Uint8List.sublistView(memory, start, end);
      return;
    }
    final file = _fileForKey(detailKey);
    if (!await file.exists()) {
      throw StateError('Diagnostic detail payload does not exist.');
    }
    final length = await file.length();
    final start = range?.offset ?? 0;
    if (start > length) {
      throw RangeError.range(start, 0, length, 'range.offset');
    }
    final end = range == null ? length : min(length, start + range.length);
    _leases[detailKey] = (_leases[detailKey] ?? 0) + 1;
    try {
      yield* file.openRead(start, end);
    } finally {
      final remaining = (_leases[detailKey] ?? 1) - 1;
      if (remaining <= 0) {
        _leases.remove(detailKey);
      } else {
        _leases[detailKey] = remaining;
      }
    }
  }

  Future<bool> delete(String detailKey) async {
    _ensureOpen();
    validateDiagnosticOpaqueId(detailKey, 'detailKey');
    if ((_leases[detailKey] ?? 0) > 0) return false;
    final memory = _memoryDetails.remove(detailKey);
    if (memory != null) _memoryBytes -= memory.length;
    final file = _fileForKey(detailKey);
    if (await file.exists()) await file.delete();
    return true;
  }

  Future<void> clearMemoryDetails(Iterable<String> detailKeys) async {
    for (final key in detailKeys) {
      final memory = _memoryDetails.remove(key);
      if (memory != null) _memoryBytes -= memory.length;
    }
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

  Future<Set<String>> listDetailKeys() async {
    _ensureOpen();
    final keys = <String>{..._memoryDetails.keys};
    if (!await detailsRoot.exists()) return keys;
    await for (final entity in detailsRoot.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.txt')) continue;
      final name = entity.uri.pathSegments.last;
      final key = name.substring(0, name.length - 4);
      if (_validDetailKey.hasMatch(key)) keys.add(key);
    }
    return keys;
  }

  Future<DiagnosticTextDetailStatistics> getStatistics() async {
    _ensureOpen();
    var count = _memoryDetails.length;
    var bytes = 0;
    if (await detailsRoot.exists()) {
      await for (final entity in detailsRoot.list(followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.txt')) continue;
        count += 1;
        bytes += await entity.length();
      }
    }
    return DiagnosticTextDetailStatistics(detailCount: count, detailTextBytes: bytes, memoryDetailBytes: _memoryBytes);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _memoryDetails.clear();
    _memoryBytes = 0;
  }

  Future<void> _commitTextFile(String detailKey, Uint8List bytes) async {
    final staging = File('${stagingRoot.path}${Platform.pathSeparator}$detailKey.partial.txt');
    final target = _fileForKey(detailKey);
    try {
      await staging.writeAsBytes(bytes, flush: true);
      if (await target.exists()) await target.delete();
      await staging.rename(target.path);
    } catch (_) {
      if (await staging.exists()) {
        try {
          await staging.delete();
        } catch (_) {
          // Preserve the authoritative write failure.
        }
      }
      rethrow;
    }
  }

  File _fileForKey(String detailKey) {
    if (!_validDetailKey.hasMatch(detailKey)) {
      throw ArgumentError.value(detailKey, 'detailKey');
    }
    return File('${detailsRoot.path}${Platform.pathSeparator}$detailKey.txt');
  }

  void _ensureOpen() {
    if (_closed) throw StateError('DiagnosticTextDetailStore is closed.');
  }
}

final RegExp _validDetailKey = RegExp(r'^[A-Za-z0-9_-]{8,128}$');
