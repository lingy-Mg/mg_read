/// Streams a file into an Android SAF-created document.
///
/// The native local-import channel owns the create-document picker and its URI
/// token. This helper owns bounded writes, cancellation, failed-output cleanup,
/// and optional deletion of temporary input. Platform selection belongs to
/// the caller so the channel protocol remains directly testable.
library;

import 'dart:io';

import 'package:flutter/services.dart';

final class AndroidBackupFileExporter {
  const AndroidBackupFileExporter({this._channel = const MethodChannel('mg_read/local_import')});

  static const int maxChunkBytes = 256 * 1024;
  final MethodChannel _channel;

  Future<bool> exportFile(
    String path, {
    String? fileName,
    String mimeType = 'application/octet-stream',
    bool deleteSourceAfterExport = true,
  }) async {
    String? token;
    try {
      final response = await _channel.invokeMapMethod<String, Object?>('createExport', <String, Object?>{
        'fileName': fileName ?? _fileName(path),
        'mimeType': mimeType,
      });
      if (response == null) return false;
      token = response['token'] as String?;
      if (token == null || token.isEmpty) throw const FormatException('invalid_export_token');

      await for (final chunk in File(path).openRead()) {
        for (var offset = 0; offset < chunk.length; offset += maxChunkBytes) {
          final end = (offset + maxChunkBytes).clamp(0, chunk.length);
          final data = Uint8List.fromList(chunk.sublist(offset, end));
          await _channel.invokeMethod<void>('writeChunk', <String, Object?>{'token': token, 'data': data});
        }
      }
      await _channel.invokeMethod<void>('finishExport', <String, Object?>{'token': token, 'success': true});
      token = null;
      return true;
    } on Object {
      if (token != null) await _finishFailedExport(token);
      rethrow;
    } finally {
      if (deleteSourceAfterExport) {
        final temporary = File(path);
        try {
          if (await temporary.exists()) await temporary.delete();
        } on FileSystemException {
          // A stale temporary file can be cleared independently of the SAF result.
        }
      }
    }
  }

  Future<void> _finishFailedExport(String token) async {
    try {
      await _channel.invokeMethod<void>('finishExport', <String, Object?>{'token': token, 'success': false});
    } on Object {
      // Keep the original export error. Native teardown also releases tokens.
    }
  }

  static String _fileName(String path) => path.split(RegExp(r'[/\\]')).last;
}
