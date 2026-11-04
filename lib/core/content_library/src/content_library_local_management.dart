/// Explicit local metadata/cover edits and reversible document-version changes.
/// User cover objects are durable originals, never part of regenerable caches.
part of 'content_library.dart';

Future<Map<String, Object?>> _prepareLocalCover(LocalDocumentObjectStore store, List<int> bytes) async {
  if (bytes.length > 8 * 1024 * 1024 || bytes.isEmpty) throw const LocalDocumentException('cover_too_large');
  String? mime;
  if (bytes.length >= 8 && bytes.take(8).join(',') == '137,80,78,71,13,10,26,10') mime = 'image/png';
  if (bytes.length >= 3 && bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff) mime = 'image/jpeg';
  if (bytes.length >= 12 &&
      ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
      ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') {
    mime = 'image/webp';
  }
  if (bytes.length >= 6 && ['GIF87a', 'GIF89a'].contains(ascii.decode(bytes.sublist(0, 6), allowInvalid: true))) mime = 'image/gif';
  if (mime == null) throw const LocalDocumentException('unsupported_cover');
  final hash = await _hashLocalCover(bytes);
  await store.commitSmallOriginal(hash, bytes);
  return {'coverHash': hash, 'coverMimeType': mime};
}

Future<String> _hashLocalCover(List<int> bytes) => Isolate.run(() => document_crypto.sha256.convert(bytes).toString());

extension LocalDocumentManagement on ContentLibrary {
  Future<void> updateLocalDocumentCover(LibraryItemId id, {required List<int>? bytes, String mimeType = 'image/png'}) =>
      _withStorageMaintenance(() async {
        final row = await _persistence.metadataRecords.contentLibrary.readItem(id.value);
        if (row == null || row.values['origin_kind'] != 'local') throw const LocalDocumentException('item_missing');
        final details = Map<String, Object?>.from(jsonDecode(row.values['details_json']! as String) as Map);
        final local = Map<String, Object?>.from(details['local'] as Map);
        if (bytes == null) {
          local.remove('coverHash');
          local.remove('coverMimeType');
        } else {
          if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) throw const LocalDocumentException('cover_too_large');
          String? detected;
          if (bytes.length >= 8 && bytes.take(8).join(',') == '137,80,78,71,13,10,26,10') detected = 'image/png';
          if (bytes.length >= 3 && bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff) detected = 'image/jpeg';
          if (bytes.length >= 12 &&
              ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
              ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') {
            detected = 'image/webp';
          }
          if (bytes.length >= 6 && ['GIF87a', 'GIF89a'].contains(ascii.decode(bytes.sublist(0, 6), allowInvalid: true))) {
            detected = 'image/gif';
          }
          if (detected == null) throw const LocalDocumentException('unsupported_cover');
          final hash = document_crypto.sha256.convert(bytes).toString();
          await _localFiles.commitSmallOriginal(hash, bytes);
          local.addAll({'coverHash': hash, 'coverMimeType': detected});
        }
        details['local'] = local;
        await _persistence.metadataRecords.contentLibrary.updateLocalDetails(
          id.value,
          row.values['item_revision']! as int,
          row.values['title']! as String,
          row.values['author'] as String?,
          jsonEncode(details),
        );
      });

  /// Returns a preview. Restoring still requires the normal explicit commit.
  Future<LocalImportSnapshot> restorePreviousLocalDocument(LibraryItemId id) async {
    final row = await _persistence.metadataRecords.contentLibrary.readItem(id.value);
    if (row == null || row.values['origin_kind'] != 'local') throw const LocalDocumentException('item_missing');
    final details = Map<String, Object?>.from(jsonDecode(row.values['details_json']! as String) as Map);
    final previous = (details['local'] as Map?)?['previous'];
    if (previous is! Map || previous['generation'] is! String || previous['rawSha256'] is! String) {
      throw const LocalDocumentException('previous_version_missing');
    }
    final generation = previous['generation']! as String;
    _localFiles.acquire(generation);
    try {
      final manifest = await _localFiles.readGeneration(generation);
      final document = ParsedLocalDocument.fromJson(Map<String, Object?>.from(manifest['document']! as Map));
      final hash = previous['rawSha256']! as String;
      final result = await prepareLocalImport(
        LocalImportInput(
          fileName: '${row.values['title']}.${document.format.name}',
          bytes: await _localFiles.originalLength(hash),
          openRead: () => _localFiles.openOriginal(hash),
        ),
        options: LocalDocumentParseOptions.fromJson(Map<String, Object?>.from(manifest['options'] as Map? ?? const {})),
        replaceItemId: id,
      );
      if (result.status == LocalImportStatus.awaitingConfirmation) {
        final journal = await _localJob(result.id);
        journal['restoreLocationsFromGeneration'] = row.values['active_generation'];
        await _saveLocalJob(journal);
      }
      return result;
    } finally {
      _localFiles.release(generation);
    }
  }
}
