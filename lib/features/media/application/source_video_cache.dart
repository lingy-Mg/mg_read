/// App-scoped offline video downloads, keyed by the full source episode identity.
/// A download is discoverable only after its media and manifest are published
/// together. URLs, headers, and resolution callbacks are never written to disk.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mg_read_video_player/mg_read_video_player.dart';
import 'package:path_provider/path_provider.dart';

import '../../network_proxy/application/flutter_network_proxy_manager.dart';
import '../../network_proxy/application/network_proxy_settings.dart';
import '../data/source_video_transfer.dart';

final sourceVideoCacheProvider = Provider<SourceVideoCache>((ref) {
  final cache = SourceVideoCache(
    createClient: () => ref.read(configuredFlutterNetworkProxyManagerProvider).createHttpClient(NetworkProxyTraffic.video),
  );
  ref.onDispose(cache.dispose);
  return cache;
});

typedef SourceVideoCacheKey = ({String pluginId, String contentId, String groupId, String episodeId});

enum SourceVideoCacheStatus { queued, downloading, completed, failed }

final class SourceVideoCacheEntry {
  const SourceVideoCacheEntry._({
    required this.key,
    required this.title,
    required this.episodeTitle,
    required this.status,
    required this.updatedAt,
    this.receivedBytes = 0,
    this.totalBytes,
    this.error,
    this._mediaName,
    this._mimeType,
  });

  final SourceVideoCacheKey key;
  final String title;
  final String episodeTitle;
  final SourceVideoCacheStatus status;
  final DateTime updatedAt;
  final int receivedBytes;
  final int? totalBytes;
  final String? error;
  final String? _mediaName;
  final String? _mimeType;

  double? get progress {
    if (status == SourceVideoCacheStatus.completed) return 1;
    final total = totalBytes;
    return total == null || total <= 0 ? null : (receivedBytes / total).clamp(0.0, 1.0);
  }
}

final class SourceVideoCacheException implements Exception {
  const SourceVideoCacheException(this.message);

  final String message;

  @override
  String toString() => message;
}

final class SourceVideoCache extends ChangeNotifier {
  SourceVideoCache({Future<Directory> Function()? supportDirectory, this._createClient, int parallelDownloads = 2})
    : assert(parallelDownloads > 0),
      _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
      _parallelDownloads = parallelDownloads;

  final Future<Directory> Function() _supportDirectory;
  final Future<HttpClient> Function()? _createClient;
  final int _parallelDownloads;
  final _entries = <SourceVideoCacheKey, SourceVideoCacheEntry>{};
  final _jobs = <SourceVideoCacheKey, _DownloadJob>{};
  final _queue = Queue<_DownloadJob>();
  final _exports = <SourceVideoCacheKey, int>{};
  final _removals = <SourceVideoCacheKey, Future<void>>{};
  Future<void>? _opening;
  late Directory _root;
  int _active = 0;
  bool _disposed = false;

  Future<void> get ready => _opening ??= _initialize().onError((Object error, StackTrace stack) {
    _opening = null;
    Error.throwWithStackTrace(error, stack);
  });

  List<SourceVideoCacheEntry> get entries => _entries.values.toList()..sort((left, right) => right.updatedAt.compareTo(left.updatedAt));

  SourceVideoCacheEntry? entryOf(SourceVideoCacheKey key) => _entries[key];

  /// Playback falls back to the source if the app cache directory is unavailable.
  Future<Uri?> findPlaybackUri(SourceVideoCacheKey key) async {
    try {
      await ready;
      final entry = _entries[key];
      final file = _fileFor(key);
      if (file == null || entry == null) return null;
      final exists = await file.exists();
      if (_entries[key] != entry || _removals.containsKey(key)) return null;
      if (exists) return file.uri;
      _markMissing(entry);
      return null;
    } on Object {
      return null;
    }
  }

  Future<SourceVideoCacheEntry> download({
    required SourceVideoCacheKey key,
    required String title,
    required String episodeTitle,
    required Future<VideoEpisode> Function() resolve,
    Future<HttpClient> Function()? createClient,
  }) async {
    await ready;
    while (true) {
      if (_disposed) throw const SourceVideoCacheException('视频下载已关闭。');
      final removal = _removals[key];
      if (removal != null) {
        await removal;
        continue;
      }
      final existingJob = _jobs[key];
      if (existingJob != null) return existingJob.result.future;
      final existing = _entries[key];
      if (existing == null || existing.status != SourceVideoCacheStatus.completed) break;
      final exists = await _fileFor(key)!.exists();
      if (_disposed || _entries[key] != existing || _removals.containsKey(key)) continue;
      if (exists) return existing;
      break;
    }
    if (_exports.containsKey(key)) throw _fileInUse;

    final job = _DownloadJob(
      entry: SourceVideoCacheEntry._(
        key: key,
        title: title,
        episodeTitle: episodeTitle,
        status: SourceVideoCacheStatus.queued,
        updatedAt: DateTime.now(),
      ),
      resolve: resolve,
      createClient: createClient ?? _createClient,
    );
    _jobs[key] = job;
    _queue.add(job);
    _publish(job.entry);
    _drain();
    return job.result.future;
  }

  /// Holds the cached file for the entire platform picker and copy operation.
  Future<T> withExportFile<T>(SourceVideoCacheKey key, Future<T> Function(File file, String fileName, String mimeType) export) async {
    await ready;
    final file = _fileFor(key);
    final entry = _entries[key];
    if (_disposed || file == null || entry == null) {
      throw const SourceVideoCacheException('请先完成视频下载。');
    }
    _exports.update(key, (count) => count + 1, ifAbsent: () => 1);
    try {
      if (!await file.exists()) {
        _markMissing(entry);
        throw _missingFile;
      }
      return await export(file, _exportName(entry), entry._mimeType!);
    } finally {
      final remaining = _exports[key]! - 1;
      if (remaining == 0) {
        _exports.remove(key);
      } else {
        _exports[key] = remaining;
      }
    }
  }

  /// Cancels pending work or removes the completed media and its manifest.
  Future<void> remove(SourceVideoCacheKey key) async {
    await ready;
    final existingRemoval = _removals[key];
    if (existingRemoval != null) return existingRemoval;
    if (_exports.containsKey(key)) throw _fileInUse;
    final removal = _remove(key);
    _removals[key] = removal;
    try {
      await removal;
    } finally {
      _removals.remove(key);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final job in _jobs.values) {
      job.cancel();
    }
    for (final job in _queue) {
      job.result.complete(_failed(job, '下载已取消。'));
    }
    _queue.clear();
    _jobs.clear();
    super.dispose();
  }

  Future<void> _initialize() async {
    final root = await Directory(_child((await _supportDirectory()).path, 'video-downloads')).create(recursive: true);
    final found = <SourceVideoCacheKey, SourceVideoCacheEntry>{};
    await for (final item in root.list(followLinks: false)) {
      if (item is! Directory) continue;
      final name = _leaf(item.path);
      if (name.startsWith('.partial-') || name.startsWith('.deleted-')) {
        await _discard(item);
      } else if (RegExp(r'^[a-f0-9]{64}$').hasMatch(name)) {
        final entry = await _readManifest(item, name);
        if (entry != null) found[entry.key] = entry;
      }
    }
    _root = root;
    _entries.addAll(found);
    if (!_disposed) notifyListeners();
  }

  void _drain() {
    while (!_disposed && _active < _parallelDownloads && _queue.isNotEmpty) {
      final job = _queue.removeFirst();
      _active++;
      unawaited(_run(job));
    }
  }

  Future<void> _run(_DownloadJob job) async {
    final key = job.entry.key;
    Directory? staging;
    SourceVideoCacheEntry result;
    try {
      _publish(job.withStatus(SourceVideoCacheStatus.downloading));
      final episode = await Future.any<VideoEpisode>([
        Future<VideoEpisode>.sync(job.resolve),
        job.cancellation.future.then<VideoEpisode>((_) => throw const SourceVideoCacheException('下载已取消。')),
      ]);
      final uri = Uri.tryParse(episode.uri ?? '');
      if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
        throw const SourceVideoCacheException('数据源没有提供可下载的视频地址。');
      }
      job.checkCancellation();
      final directory = await _root.createTemp('.partial-');
      staging = directory;
      job.checkCancellation();
      final transferred = await downloadSourceVideo(
        uri: uri,
        headers: episode.httpHeaders,
        directory: directory,
        onProgress: (received, total) {
          if (job.cancellation.isCompleted) return;
          job.received = received;
          job.total = total;
          final now = DateTime.now();
          final previous = job.lastProgress;
          if (previous != null && now.difference(previous) < const Duration(milliseconds: 150)) return;
          job.lastProgress = now;
          _publish(job.withStatus(SourceVideoCacheStatus.downloading));
        },
        cancellation: job.cancellation.future,
        createClient: job.createClient,
      );
      job.checkCancellation();
      final mediaName = _leaf(transferred.file.path);
      if (!_isMediaName(mediaName)) {
        throw const SourceVideoCacheException('视频文件名无效。');
      }
      final length = await File(_child(directory.path, mediaName)).length();
      if (length <= 0) throw const SourceVideoCacheException('下载的视频文件为空。');
      result = SourceVideoCacheEntry._(
        key: key,
        title: job.entry.title,
        episodeTitle: job.entry.episodeTitle,
        status: SourceVideoCacheStatus.completed,
        updatedAt: DateTime.now(),
        receivedBytes: length,
        totalBytes: length,
        mediaName: mediaName,
        mimeType: transferred.mimeType,
      );
      await _writeManifest(directory, result);
      final target = _directoryFor(key);
      // A previous download without a valid manifest is absent from the index.
      // Keep it during initialization, and replace it only on an explicit retry.
      await _retire(target);
      job.checkCancellation();
      await directory.rename(target.path);
      staging = null;
    } on SourceVideoCacheException catch (error) {
      result = _failed(job, error.message);
    } on SourceVideoTransferException catch (error) {
      result = _failed(job, job.cancellation.isCompleted ? '下载已取消。' : error.message);
    } on Object {
      result = _failed(job, job.cancellation.isCompleted ? '下载已取消。' : '视频下载失败，请检查网络和存储空间后重试。');
    } finally {
      if (staging != null) await _discard(staging);
    }
    _jobs.remove(key);
    _active--;
    _publish(result);
    job.result.complete(result);
    _drain();
  }

  Future<void> _remove(SourceVideoCacheKey key) async {
    final job = _jobs[key];
    if (job != null) {
      job.cancel();
      if (_queue.remove(job)) {
        _jobs.remove(key);
        job.result.complete(_failed(job, '下载已取消。'));
      }
      await job.result.future;
    }
    await _retire(_directoryFor(key));
    _entries.remove(key);
    if (!_disposed) notifyListeners();
  }

  Future<void> _retire(Directory directory) async {
    if (!await directory.exists()) return;
    // Rename out of the index before removing contents, so an interrupted
    // deletion cannot leave a published entry with only some of its files.
    final deleted = await _root.createTemp('.deleted-');
    try {
      await directory.rename(_child(deleted.path, 'entry'));
    } finally {
      await _discard(deleted);
    }
  }

  File? _fileFor(SourceVideoCacheKey key) {
    if (_removals.containsKey(key)) return null;
    final name = _entries[key]?._mediaName;
    return name == null ? null : File(_child(_directoryFor(key).path, name));
  }

  Directory _directoryFor(SourceVideoCacheKey key) => Directory(_child(_root.path, _directoryName(key)));

  void _publish(SourceVideoCacheEntry entry) {
    if (_disposed) return;
    _entries[entry.key] = entry;
    notifyListeners();
  }

  void _markMissing(SourceVideoCacheEntry entry) {
    if (_entries[entry.key] != entry) return;
    _publish(
      SourceVideoCacheEntry._(
        key: entry.key,
        title: entry.title,
        episodeTitle: entry.episodeTitle,
        status: SourceVideoCacheStatus.failed,
        updatedAt: entry.updatedAt,
        error: _missingFile.message,
      ),
    );
  }

  static SourceVideoCacheEntry _failed(_DownloadJob job, String message) => job.withStatus(SourceVideoCacheStatus.failed, error: message);

  static Future<void> _writeManifest(Directory directory, SourceVideoCacheEntry entry) =>
      File(_child(directory.path, 'entry.json')).writeAsString(
        jsonEncode({
          'version': 1,
          'pluginId': entry.key.pluginId,
          'contentId': entry.key.contentId,
          'groupId': entry.key.groupId,
          'episodeId': entry.key.episodeId,
          'title': entry.title,
          'episodeTitle': entry.episodeTitle,
          'updatedAt': entry.updatedAt.toIso8601String(),
          'bytes': entry.receivedBytes,
          'media': entry._mediaName,
          'mime': entry._mimeType,
        }),
        flush: true,
      );

  static Future<SourceVideoCacheEntry?> _readManifest(Directory directory, String name) async {
    try {
      final manifest = File(_child(directory.path, 'entry.json'));
      if (await manifest.length() > 64 * 1024) return null;
      final value = jsonDecode(await manifest.readAsString()) as Map<String, Object?>;
      if (value['version'] != 1) return null;
      final key = (
        pluginId: value['pluginId'] as String,
        contentId: value['contentId'] as String,
        groupId: value['groupId'] as String,
        episodeId: value['episodeId'] as String,
      );
      final media = value['media'] as String;
      final bytes = value['bytes'] as int;
      if (_directoryName(key) != name || !_isMediaName(media) || bytes <= 0) return null;
      if (await File(_child(directory.path, media)).length() != bytes) return null;
      return SourceVideoCacheEntry._(
        key: key,
        title: value['title'] as String,
        episodeTitle: value['episodeTitle'] as String,
        status: SourceVideoCacheStatus.completed,
        updatedAt: DateTime.parse(value['updatedAt'] as String),
        receivedBytes: bytes,
        totalBytes: bytes,
        mediaName: media,
        mimeType: value['mime'] as String,
      );
    } on Object {
      return null;
    }
  }

  static Future<void> _discard(Directory directory) async {
    try {
      await directory.delete(recursive: true);
    } on FileSystemException {
      // The next initialization can retry abandoned temporary directories.
    }
  }

  static String _directoryName(SourceVideoCacheKey key) =>
      sha256.convert(utf8.encode(jsonEncode([key.pluginId, key.contentId, key.groupId, key.episodeId]))).toString();

  static bool _isMediaName(String value) => RegExp(r'^[a-zA-Z0-9_-]+\.[a-zA-Z0-9]+$').hasMatch(value) && value != 'entry.json';

  static String _exportName(SourceVideoCacheEntry entry) {
    final label = entry.episodeTitle == entry.title ? entry.title : '${entry.title} - ${entry.episodeTitle}';
    final cleaned = String.fromCharCodes(
      label.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_').runes.take(90),
    ).trim().replaceAll(RegExp(r'[. ]+$'), '');
    final safe = cleaned.isEmpty || RegExp(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)', caseSensitive: false).hasMatch(cleaned)
        ? '视频-$cleaned'
        : cleaned;
    return '$safe.${entry._mediaName!.split('.').last}';
  }

  static String _child(String parent, String name) => '$parent${Platform.pathSeparator}$name';

  static String _leaf(String path) => path.split(RegExp(r'[/\\]')).last;
}

final class _DownloadJob {
  _DownloadJob({required this.entry, required this.resolve, required this.createClient});

  final SourceVideoCacheEntry entry;
  final Future<VideoEpisode> Function() resolve;
  final Future<HttpClient> Function()? createClient;
  final cancellation = Completer<void>();
  final result = Completer<SourceVideoCacheEntry>();
  int received = 0;
  int? total;
  DateTime? lastProgress;

  void cancel() {
    if (!cancellation.isCompleted) cancellation.complete();
  }

  void checkCancellation() {
    if (cancellation.isCompleted) throw const SourceVideoCacheException('下载已取消。');
  }

  SourceVideoCacheEntry withStatus(SourceVideoCacheStatus status, {String? error}) => SourceVideoCacheEntry._(
    key: entry.key,
    title: entry.title,
    episodeTitle: entry.episodeTitle,
    status: status,
    updatedAt: entry.updatedAt,
    receivedBytes: received,
    totalBytes: total,
    error: error,
  );
}

const _fileInUse = SourceVideoCacheException('视频正在使用，请在播放或导出结束后删除。');
const _missingFile = SourceVideoCacheException('视频缓存文件已丢失，请重新下载。');
