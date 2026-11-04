/// Streams one SAF-selected MgRead backup into an app-owned temporary file.
///
/// The native channel owns document handles; this importer bounds every read,
/// enforces the backup size limit, and releases all handles on every outcome.
/// It deletes only its previous/current temporary backup, never other cache files.
library;

import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../lan_sync/domain/lan_sync_models.dart';

final class AndroidBackupFileImporter {
  AndroidBackupFileImporter({this._channel = const MethodChannel('mg_read/local_import'), Future<Directory> Function()? temporaryDirectory})
    : _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;

  static const int maxChunkBytes = 256 * 1024;
  static const int maxBackupBytes = lanSyncMaxBatchBytes + lanSyncMaxManifestBytes + 12;
  final MethodChannel _channel;
  final Future<Directory> Function() _temporaryDirectory;
  String? _previousPath;

  Future<String?> pickImportPath() async {
    await _deletePrevious();
    final picked = await _channel.invokeListMethod<Object?>('pickFiles', <String, Object?>{'kind': 'backup'});
    if (picked == null || picked.isEmpty) return null;

    final tokens = <String>{};
    try {
      final handles = <Map<Object?, Object?>>[];
      for (final entry in picked) {
        if (entry is! Map) continue;
        final handle = Map<Object?, Object?>.from(entry);
        handles.add(handle);
        final rawToken = handle['token'];
        if (rawToken is String && rawToken.isNotEmpty) tokens.add(rawToken);
      }
      final selected = handles.isEmpty ? null : handles.first;
      final token = selected?['token'] as String?;
      if (token == null || token.isEmpty) throw const FormatException('invalid_backup_handle');
      final declaredBytes = selected!['bytes'] as int?;
      if (declaredBytes != null && (declaredBytes < 0 || declaredBytes > maxBackupBytes)) {
        throw const FormatException('backup_too_large');
      }

      final directory = await _temporaryDirectory();
      final random = Random.secure();
      final file = File(
        '${directory.path}${Platform.pathSeparator}mgread-import-${DateTime.now().microsecondsSinceEpoch}-${random.nextInt(1 << 32)}.mgread',
      );
      final output = await file.open(mode: FileMode.writeOnly);
      var total = 0;
      var eof = false;
      var complete = false;
      try {
        while (!eof) {
          final response = await _channel.invokeMapMethod<Object?, Object?>('readChunk', <String, Object?>{
            'token': token,
            'maxBytes': maxChunkBytes,
          });
          if (response == null) throw const FormatException('invalid_backup_chunk');
          final raw = response['data'];
          final bytes = raw is Uint8List
              ? raw
              : raw is List<int>
              ? raw
              : null;
          if (bytes == null || bytes.length > maxChunkBytes) throw const FormatException('invalid_backup_chunk');
          eof = response['eof'] == true;
          if (bytes.isEmpty && !eof) throw const FormatException('invalid_backup_chunk');
          total += bytes.length;
          if (total > maxBackupBytes) throw const FormatException('backup_too_large');
          if (declaredBytes != null && total > declaredBytes) throw const FormatException('backup_size_mismatch');
          if (bytes.isNotEmpty) await output.writeFrom(bytes);
          if (declaredBytes != null && eof && total != declaredBytes) {
            throw const FormatException('backup_size_mismatch');
          }
        }
        await output.flush();
        await output.close();
        complete = true;
        _previousPath = file.path;
        return file.path;
      } finally {
        if (!complete) {
          try {
            await output.close();
          } on FileSystemException {
            // Preserve the original read/write/validation failure.
          }
          try {
            await file.delete();
          } on FileSystemException {
            // Preserve the original read/write/validation failure.
          }
        }
      }
    } finally {
      for (final token in tokens) {
        await _release(token);
      }
    }
  }

  Future<void> _release(String token) async {
    try {
      await _channel.invokeMethod<void>('release', <String, Object?>{'token': token});
    } on Object {
      // Native teardown also releases outstanding handles.
    }
  }

  Future<void> _deletePrevious() async {
    final path = _previousPath;
    _previousPath = null;
    if (path == null) return;
    try {
      await File(path).delete();
    } on FileSystemException {
      // A missing temp file is already cleared.
    }
  }
}
