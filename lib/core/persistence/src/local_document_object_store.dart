/// App-private immutable local-document objects. Only ContentLibrary uses this
/// infrastructure adapter. Staging is never visible to a reader or transport.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:mg_read/core/content_limits.dart';

final class LocalDocumentObjectStore {
  LocalDocumentObjectStore(Directory appRoot) : _root = Directory('${appRoot.path}/files/local-documents');
  final Directory _root;
  final Map<String, int> _leases = {};
  final Map<String, int> _coverLeases = {};
  static final _key = RegExp(r'^[A-Za-z0-9_-]{16,128}$');

  Future<Directory> staging(String taskId) async {
    _validate(taskId);
    final result = Directory('${_root.path}/staging/$taskId');
    await result.create(recursive: true);
    return result;
  }

  Future<void> publish({required String taskId, required String generation, required String hash}) async {
    _validate(generation);
    _validate(hash);
    final stage = await staging(taskId);
    final raw = File('${stage.path}/source');
    final blob = _blob(hash);
    await blob.parent.create(recursive: true);
    if (await raw.exists()) {
      if (await blob.exists()) {
        await raw.delete();
      } else {
        await raw.rename(blob.path);
      }
    }
    if (!await blob.exists()) throw const FileSystemException('Local document original is missing');
    final parsed = Directory('${stage.path}/parsed');
    final target = _generation(generation);
    await target.parent.create(recursive: true);
    if (!await target.exists()) await parsed.rename(target.path);
  }

  Future<void> removeStaging(String taskId) async {
    _validate(taskId);
    final folder = Directory('${_root.path}/staging/$taskId');
    if (await folder.exists()) await folder.delete(recursive: true);
  }

  Future<Map<String, Object?>> readGeneration(String generation) =>
      readJson(generation, 'manifest.json', maxBytes: ContentLimits.epubContainerBytes);

  Future<Map<String, Object?>> readJson(String generation, String relative, {int maxBytes = ContentLimits.inlineBytes}) async {
    final file = _file(generation, relative);
    if (await file.length() > maxBytes) throw const FormatException('local_document_object_too_large');
    return Isolate.run(() => Map<String, Object?>.from(jsonDecode(file.readAsStringSync()) as Map));
  }

  Future<List<int>> readResource(String generation, String relative, {int maxBytes = ContentLimits.epubResourceBytes}) async {
    final file = _file(generation, relative);
    if (await file.length() > maxBytes) throw const FormatException('local_document_resource_too_large');
    return file.readAsBytes();
  }

  Stream<List<int>> openOriginal(String hash) {
    _validate(hash);
    return _blob(hash).openRead();
  }

  Future<int> originalLength(String hash) {
    _validate(hash);
    return _blob(hash).length();
  }

  Future<void> commitSmallOriginal(String hash, List<int> bytes) async {
    _validate(hash);
    if (bytes.length > ContentLimits.coverBytes) throw const FormatException('cover_too_large');
    final file = _blob(hash);
    await file.parent.create(recursive: true);
    if (await file.exists()) return;
    final temp = File('${file.path}.part');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(file.path);
  }

  Future<List<int>> readSmallOriginal(String hash) async {
    _validate(hash);
    final file = _blob(hash);
    if (await file.length() > ContentLimits.coverBytes) throw const FormatException('cover_too_large');
    return file.readAsBytes();
  }

  Future<void> restoreDraft(String taskId, String hash) async {
    _validate(taskId);
    _validate(hash);
    final stage = await staging(taskId);
    final output = Directory('${stage.path}/parsed');
    final published = _generation(taskId);
    if (!await output.exists() && await published.exists()) await published.rename(output.path);
    final source = File('${stage.path}/source');
    if (!await source.exists() && await _blob(hash).exists()) await _blob(hash).copy(source.path);
  }

  /// A generation remains readable until every reader/exporter releases it.
  void acquire(String generation, {String? coverHash}) {
    _validate(generation);
    _leases.update(generation, (n) => n + 1, ifAbsent: () => 1);
    if (coverHash != null) {
      _validate(coverHash);
      _coverLeases.update(coverHash, (n) => n + 1, ifAbsent: () => 1);
    }
  }

  void release(String generation, {String? coverHash}) {
    final count = _leases[generation];
    if (count == null) return;
    if (coverHash != null) {
      final covers = _coverLeases[coverHash] ?? 0;
      if (covers <= 1) {
        _coverLeases.remove(coverHash);
      } else {
        _coverLeases[coverHash] = covers - 1;
      }
    }
    if (count <= 1) {
      _leases.remove(generation);
    } else {
      _leases[generation] = count - 1;
    }
  }

  Future<int> collect({required Set<String> generations, required Set<String> hashes, Set<String> activeTasks = const {}}) async {
    var released = 0;
    final retainedHashes = {...hashes, ..._coverLeases.keys};
    final generationsRoot = Directory('${_root.path}/generations');
    if (await generationsRoot.exists()) {
      await for (final entity in generationsRoot.list(followLinks: false)) {
        final id = entity.uri.pathSegments.where((part) => part.isNotEmpty).last;
        if (generations.contains(id) || _leases.containsKey(id)) {
          try {
            final manifest = await readGeneration(id);
            if (manifest['rawSha256'] case final String hash) retainedHashes.add(hash);
          } on Object {
            /* Metadata and original remain authoritative on damage. */
          }
          continue;
        }
        released += await _entityBytes(entity);
        await entity.delete(recursive: entity is Directory);
      }
    }
    final blobs = Directory('${_root.path}/originals');
    if (await blobs.exists()) {
      await for (final entity in blobs.list(followLinks: false)) {
        final id = entity.uri.pathSegments.last.split('.').first;
        if (!retainedHashes.contains(id)) {
          released += await _entityBytes(entity);
          await entity.delete(recursive: entity is Directory);
        }
      }
    }
    final stages = Directory('${_root.path}/staging');
    if (await stages.exists()) {
      await for (final entity in stages.list(followLinks: false)) {
        final id = entity.uri.pathSegments.where((part) => part.isNotEmpty).last;
        if (activeTasks.contains(id)) continue;
        final modified = (await entity.stat()).modified;
        if (DateTime.now().difference(modified) > const Duration(days: 7)) {
          released += await _entityBytes(entity);
          await entity.delete(recursive: entity is Directory);
        }
      }
    }
    return released;
  }

  Future<int> usageBytes() => _entityBytes(_root);
  Future<int> _entityBytes(FileSystemEntity entity) async {
    if (entity is File) return entity.length();
    if (entity is! Directory || !await entity.exists()) return 0;
    var size = 0;
    await for (final child in entity.list(recursive: true, followLinks: false)) {
      if (child is File) size += await child.length();
    }
    return size;
  }

  File _blob(String hash) => File('${_root.path}/originals/$hash.source');
  Directory _generation(String generation) {
    _validate(generation);
    return Directory('${_root.path}/generations/$generation');
  }

  File _file(String generation, String relative) {
    if (relative.isEmpty ||
        relative.contains('\\') ||
        relative.startsWith('/') ||
        relative.contains(':') ||
        relative.split('/').any((part) => part == '..' || part == '.' || part.isEmpty)) {
      throw const FormatException('invalid_local_document_object');
    }
    return File('${_generation(generation).path}/$relative');
  }

  void _validate(String key) {
    if (!_key.hasMatch(key)) throw ArgumentError.value(key, 'objectKey');
  }
}
