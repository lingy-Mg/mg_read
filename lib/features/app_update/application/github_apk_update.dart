/// Android-only GitHub Release update discovery and install orchestration.
///
/// Checks are initiated by the app shell after its first frame. A small marker
/// in application support storage limits checks across cold starts. Manifest
/// requests include a cache-busting query because GitHub's `latest/download`
/// redirect can otherwise serve stale release metadata. Release assets are
/// bounded, SHA-256 verified, and passed to Android's Package Installer; the
/// system remains responsible for signing and user confirmation.
library;

import 'update_check_result.dart';
export 'update_check_result.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'package:mg_read/features/lan_sync/application/app_update_service.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_checksum.dart';
import 'package:mg_read/features/lan_sync/domain/app_update_models.dart';

const Duration githubApkUpdateCheckInterval = Duration(minutes: 30);
const String githubApkUpdateManifestUrl = 'https://github.com/lingy-Mg/mg_read/releases/latest/download/update.json';
const int _maxReleaseMetadataBytes = 256 * 1024;
const Duration _requestTimeout = Duration(seconds: 12);
const int _parallelApkDownloadCount = 4;

@immutable
final class GitHubApkDownloadProgress {
  const GitHubApkDownloadProgress({required this.receivedBytes, required this.totalBytes});

  final int receivedBytes;
  final int totalBytes;

  double? get fraction => totalBytes > 0 ? (receivedBytes / totalBytes).clamp(0, 1).toDouble() : null;
}

typedef GitHubApkDownloadProgressCallback = void Function(GitHubApkDownloadProgress progress);

bool isGitHubApkUpdateCheckDue(DateTime? lastCheck, DateTime now) =>
    lastCheck == null || now.isBefore(lastCheck) || now.difference(lastCheck) >= githubApkUpdateCheckInterval;

String githubAndroidApkAssetName(AppVersionInfo version) =>
    'MgRead-${version.version}${version.buildNumber > 0 ? '+${version.buildNumber}' : ''}-android-arm64.apk';

final githubApkUpdateCoordinatorProvider = Provider<GitHubApkUpdateCoordinator>((ref) {
  final service = ref.watch(appUpdateServiceProvider);
  return GitHubApkUpdateCoordinator(
    currentVersion: service.currentVersion,
    downloadAndInstall: (release, {onProgress}) async {
      await service.ensureInstallPermission();
      final prepared = await release.download(onProgress: onProgress);
      try {
        await service.launchInstaller(prepared.file, prepared.descriptor);
      } finally {
        await prepared.close();
      }
    },
  );
});

@immutable
final class GitHubApkRelease {
  const GitHubApkRelease({
    required this.version,
    required this.apkUrl,
    required this.apkName,
    required this.sha256,
    required this.repository,
    required this.title,
    required this.tag,
    required this.releaseUrl,
    required this.tagUrl,
    required this.publishedAt,
    required this.author,
    required this.targetCommitish,
    required this.releaseNotes,
    required this.assets,
    this.authorUrl,
    this.authorAvatarUrl,
    this.releaseId,
    this.createdAt,
    this.commitSha,
    this.commitUrl,
    this.compareUrl,
    this.checksumUrl,
  });

  final AppVersionInfo version;
  final Uri apkUrl;
  final String apkName;
  final String sha256;
  final String repository;
  final String title;
  final String tag;
  final Uri releaseUrl;
  final Uri tagUrl;
  final DateTime publishedAt;
  final String author;
  final Uri? authorUrl;
  final Uri? authorAvatarUrl;
  final String targetCommitish;
  final String releaseNotes;
  final List<GitHubApkReleaseAsset> assets;
  final int? releaseId;
  final DateTime? createdAt;
  final String? commitSha;
  final Uri? commitUrl;
  final Uri? compareUrl;
  final Uri? checksumUrl;

  /// Stable machine-readable release record for diagnostics and update logs.
  Map<String, Object?> toJson() => <String, Object?>{
    'schema': 'mgread.github-release.v1',
    'repository': repository,
    'releaseId': releaseId,
    'title': title,
    'version': version.displayVersion,
    'tag': tag,
    'publishedAt': publishedAt.toUtc().toIso8601String(),
    'createdAt': createdAt?.toUtc().toIso8601String(),
    'author': author,
    'authorUrl': authorUrl?.toString(),
    'authorAvatarUrl': authorAvatarUrl?.toString(),
    'targetCommitish': targetCommitish,
    'latest': true,
    'draft': false,
    'prerelease': false,
    'commitSha': commitSha,
    'releaseUrl': releaseUrl.toString(),
    'tagUrl': tagUrl.toString(),
    'commitUrl': commitUrl?.toString(),
    'compareUrl': compareUrl?.toString(),
    'releaseNotes': releaseNotes,
    'apk': <String, Object?>{'name': apkName, 'url': apkUrl.toString(), 'sha256': sha256},
    'checksumUrl': checksumUrl?.toString(),
    'assets': assets.map((asset) => asset.toJson()).toList(growable: false),
  };

  /// Human-readable, one-field-per-line log form; notes start after two LFs.
  String toLogText() {
    final fields = <String>[
      '记录类型: GitHub Release',
      '仓库: $repository',
      if (releaseId != null) 'Release ID: $releaseId',
      '标题: $title',
      '版本: ${version.displayVersion}',
      '标签: $tag',
      '发布时间: ${publishedAt.toUtc().toIso8601String()}',
      if (createdAt != null) '创建时间: ${createdAt!.toUtc().toIso8601String()}',
      '发布者: $author',
      if (authorUrl != null) '发布者主页: $authorUrl',
      if (authorAvatarUrl != null) '发布者头像: $authorAvatarUrl',
      '目标提交: $targetCommitish',
      '最新发布: 是',
      '草稿: 否',
      '预发布: 否',
      if (commitSha != null) '提交 SHA: $commitSha',
      'Release 地址: $releaseUrl',
      '标签地址: $tagUrl',
      if (commitUrl != null) '提交地址: $commitUrl',
      if (compareUrl != null) '版本比较: $compareUrl',
      'APK 文件: $apkName',
      'APK 下载: $apkUrl',
      if (sha256.isNotEmpty) 'APK SHA-256: $sha256',
      if (checksumUrl != null) '校验文件: $checksumUrl',
      '制品数量: ${assets.length}',
      for (var index = 0; index < assets.length; index++)
        '制品 ${index + 1}: ${assets[index].name} | ${assets[index].size} bytes | 下载 ${assets[index].downloadCount} 次 | ${assets[index].contentType} | 创建 ${assets[index].createdAt?.toUtc().toIso8601String() ?? "unknown"} | 更新 ${assets[index].updatedAt?.toUtc().toIso8601String() ?? "unknown"} | ${assets[index].downloadUrl}',
    ];
    return '${fields.join('\n')}\n\n${releaseNotes.trim()}';
  }

  Future<PreparedAppPackage> download({
    HttpClient? client,
    Future<Directory> Function()? temporaryDirectory,
    GitHubApkDownloadProgressCallback? onProgress,
  }) async {
    final http = client ?? HttpClient();
    final ownsClient = client == null;
    final temporary = await (temporaryDirectory ?? getTemporaryDirectory)();
    final directory = await temporary.createTemp('mgread-github-update-');
    final file = File('${directory.path}${Platform.pathSeparator}$apkName');
    final apkAssets = assets.where((asset) => asset.name == apkName);
    final expectedSize = apkAssets.isEmpty ? 0 : apkAssets.first.size;
    void reportProgress(int receivedBytes, int totalBytes) {
      try {
        onProgress?.call(GitHubApkDownloadProgress(receivedBytes: receivedBytes, totalBytes: totalBytes));
      } on Object {
        // A progress surface must never interrupt a verified package download.
      }
    }

    try {
      if (expectedSize > 0) reportProgress(0, expectedSize);
      final downloadedBytes = await _downloadApkToFile(http, file, expectedSize, reportProgress);
      final digestSink = _DigestSink();
      final hashSink = crypto.sha256.startChunkedConversion(digestSink);
      var verifiedBytes = 0;
      final checksum = LanSyncChecksumSink();
      try {
        await for (final chunk in file.openRead()) {
          verifiedBytes += chunk.length;
          if (verifiedBytes > appUpdateMaxPackageBytes) throw const FormatException('github_apk_size_invalid');
          hashSink.add(chunk);
          checksum.add(chunk);
        }
      } finally {
        hashSink.close();
      }
      if (verifiedBytes != downloadedBytes || (expectedSize > 0 && verifiedBytes != expectedSize) || digestSink.value != sha256) {
        throw const FormatException('github_apk_hash_mismatch');
      }
      reportProgress(verifiedBytes, verifiedBytes);
      return PreparedAppPackage(
        descriptor: AppPackageDescriptor(version: version, bytes: verifiedBytes, checksum: checksum.close(), fileName: apkName),
        file: file,
        onClose: () async {
          if (await directory.exists()) await directory.delete(recursive: true);
        },
      );
    } on Object {
      if (await directory.exists()) await directory.delete(recursive: true);
      rethrow;
    } finally {
      if (ownsClient) http.close(force: true);
    }
  }

  Future<int> _downloadApkToFile(
    HttpClient http,
    File file,
    int expectedSize,
    void Function(int receivedBytes, int totalBytes) reportProgress,
  ) async {
    final probe = await _openApkResponse(http, apkUrl, range: 'bytes=0-0');
    if (probe.statusCode == HttpStatus.ok) {
      return _downloadSequentialResponse(probe, file, expectedSize, reportProgress);
    }
    if (probe.statusCode != HttpStatus.partialContent) throw const HttpException('github_apk_download_failed');

    final totalBytes = _parseContentRange(probe, expectedStart: 0, expectedEnd: 0);
    _validateApkSize(totalBytes, expectedSize);
    final firstByte = await _readBounded(probe, 1);
    if (firstByte.length != 1) throw const FormatException('github_apk_range_invalid');

    final output = await file.open(mode: FileMode.write);
    try {
      await output.writeFrom(firstByte);
      var receivedBytes = 1;
      reportProgress(receivedBytes, totalBytes);
      if (totalBytes == 1) {
        await output.flush();
        return receivedBytes;
      }

      var pendingWrites = Future<void>.value();
      Future<void> writeAt(int offset, List<int> bytes) {
        final nextWrite = pendingWrites.then((_) async {
          await output.setPosition(offset);
          await output.writeFrom(bytes);
        });
        pendingWrites = nextWrite;
        return nextWrite;
      }

      final remainingBytes = totalBytes - 1;
      final segmentCount = remainingBytes < _parallelApkDownloadCount ? remainingBytes : _parallelApkDownloadCount;
      final ranges = <({int start, int end})>[];
      for (var index = 0; index < segmentCount; index++) {
        final start = 1 + (remainingBytes * index ~/ segmentCount);
        final endExclusive = 1 + (remainingBytes * (index + 1) ~/ segmentCount);
        ranges.add((start: start, end: endExclusive - 1));
      }

      await Future.wait<void>(
        ranges.map((range) async {
          final response = await _openApkResponse(http, apkUrl, range: 'bytes=${range.start}-${range.end}');
          if (response.statusCode != HttpStatus.partialContent) throw const HttpException('github_apk_range_unsupported');
          final rangeTotal = _parseContentRange(response, expectedStart: range.start, expectedEnd: range.end);
          if (rangeTotal != totalBytes) throw const FormatException('github_apk_size_invalid');
          final expectedRangeBytes = range.end - range.start + 1;
          if (response.contentLength >= 0 && response.contentLength != expectedRangeBytes) {
            throw const FormatException('github_apk_range_invalid');
          }

          var rangeBytes = 0;
          var position = range.start;
          await for (final chunk in response.timeout(_requestTimeout)) {
            rangeBytes += chunk.length;
            if (rangeBytes > expectedRangeBytes) throw const FormatException('github_apk_range_invalid');
            await writeAt(position, chunk);
            position += chunk.length;
            receivedBytes += chunk.length;
            reportProgress(receivedBytes, totalBytes);
          }
          if (rangeBytes != expectedRangeBytes) throw const FormatException('github_apk_range_invalid');
        }),
      );
      await pendingWrites;
      if (receivedBytes != totalBytes) throw const FormatException('github_apk_size_invalid');
      await output.flush();
      return receivedBytes;
    } finally {
      await output.close();
    }
  }

  Future<int> _downloadSequentialResponse(
    HttpClientResponse response,
    File file,
    int expectedSize,
    void Function(int receivedBytes, int totalBytes) reportProgress,
  ) async {
    if (response.statusCode != HttpStatus.ok) throw const HttpException('github_apk_download_failed');
    final totalBytes = response.contentLength > 0 ? response.contentLength : expectedSize;
    _validateApkSize(totalBytes, expectedSize);

    final output = await file.open(mode: FileMode.write);
    try {
      var receivedBytes = 0;
      await for (final chunk in response.timeout(_requestTimeout)) {
        receivedBytes += chunk.length;
        if (receivedBytes > totalBytes || receivedBytes > appUpdateMaxPackageBytes) {
          throw const FormatException('github_apk_size_invalid');
        }
        await output.writeFrom(chunk);
        reportProgress(receivedBytes, totalBytes);
      }
      if (receivedBytes != totalBytes) throw const FormatException('github_apk_size_invalid');
      await output.flush();
      return receivedBytes;
    } finally {
      await output.close();
    }
  }
}

Future<HttpClientResponse> _openApkResponse(HttpClient http, Uri url, {String? range}) async {
  final request = await http.getUrl(url).timeout(_requestTimeout);
  request.headers.set(HttpHeaders.acceptHeader, 'application/octet-stream');
  request.headers.set(HttpHeaders.userAgentHeader, 'MgRead-Android-Updater');
  if (range != null) request.headers.set('range', range);
  return request.close().timeout(_requestTimeout);
}

int _parseContentRange(HttpClientResponse response, {required int expectedStart, required int expectedEnd}) {
  final value = response.headers.value('content-range');
  final match = value == null ? null : RegExp(r'^bytes (\d+)-(\d+)/(\d+)$', caseSensitive: false).firstMatch(value.trim());
  if (match == null || int.parse(match.group(1)!) != expectedStart || int.parse(match.group(2)!) != expectedEnd) {
    throw const FormatException('github_apk_range_invalid');
  }
  return int.parse(match.group(3)!);
}

void _validateApkSize(int totalBytes, int expectedSize) {
  if (totalBytes <= 0 || totalBytes > appUpdateMaxPackageBytes || (expectedSize > 0 && expectedSize != totalBytes)) {
    throw const FormatException('github_apk_size_invalid');
  }
}

@immutable
final class GitHubApkReleaseAsset {
  const GitHubApkReleaseAsset({
    required this.name,
    required this.downloadUrl,
    required this.size,
    required this.downloadCount,
    required this.contentType,
    this.createdAt,
    this.updatedAt,
  });

  final String name;
  final Uri downloadUrl;
  final int size;
  final int downloadCount;
  final String contentType;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'downloadUrl': downloadUrl.toString(),
    'size': size,
    'downloadCount': downloadCount,
    'contentType': contentType,
    'createdAt': createdAt?.toUtc().toIso8601String(),
    'updatedAt': updatedAt?.toUtc().toIso8601String(),
  };
}

/// Adapts package:crypto's streaming conversion without retaining APK bytes.
final class _DigestSink implements Sink<crypto.Digest> {
  String? value;

  @override
  void add(crypto.Digest data) => value = data.toString();

  @override
  void close() {}
}

final class GitHubApkUpdateCoordinator {
  GitHubApkUpdateCoordinator({
    required this._currentVersion,
    required this._downloadAndInstall,
    Future<Directory> Function()? supportDirectory,
    DateTime Function()? clock,
    HttpClient Function()? httpClientFactory,
    Uri? manifestUri,
    bool? isAndroid,
  }) : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       _clock = clock ?? DateTime.now,
       _httpClientFactory = httpClientFactory ?? HttpClient.new,
       _manifestUri = manifestUri ?? Uri.parse(githubApkUpdateManifestUrl),
       _isAndroid = isAndroid ?? Platform.isAndroid;

  final Future<AppVersionInfo> Function() _currentVersion;
  final Future<void> Function(GitHubApkRelease release, {GitHubApkDownloadProgressCallback? onProgress}) _downloadAndInstall;
  final Future<Directory> Function() _supportDirectory;
  final DateTime Function() _clock;
  final HttpClient Function() _httpClientFactory;
  final Uri _manifestUri;
  final bool _isAndroid;
  Future<UpdateCheckResult<GitHubApkRelease>>? _checkInFlight;
  final AutomaticCheckTiming _timing = AutomaticCheckTiming();
  bool _timingLoaded = false;
  Future<void>? _installInFlight;

  Future<UpdateCheckResult<GitHubApkRelease>> checkForUpdate({bool force = false}) async {
    if (!_isAndroid) return const UpdateCheckResult(UpdateCheckStatus.unsupported);
    final current = _checkInFlight;
    if (current != null) {
      final result = await current;
      if (!force || result.status != UpdateCheckStatus.skipped) return result;
    }
    return _checkInFlight ??= _check(force: force).whenComplete(() => _checkInFlight = null);
  }

  Future<void> install(GitHubApkRelease release, {GitHubApkDownloadProgressCallback? onProgress}) {
    if (!_isAndroid) return Future<void>.value();
    return _installInFlight ??= _downloadAndInstall(release, onProgress: onProgress).whenComplete(() => _installInFlight = null);
  }

  Future<UpdateCheckResult<GitHubApkRelease>> _check({required bool force}) async {
    await _loadTiming();
    final now = _clock();
    if (!force && !_timing.isDue(now, githubApkUpdateCheckInterval)) {
      return const UpdateCheckResult(UpdateCheckStatus.skipped);
    }
    HttpClient? client;
    try {
      client = _httpClientFactory();
      final requestUri = _manifestUri.replace(
        queryParameters: <String, String>{..._manifestUri.queryParameters, 'check': '${now.microsecondsSinceEpoch}'},
      );
      final request = await client.getUrl(requestUri).timeout(_requestTimeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      request.headers.set(HttpHeaders.userAgentHeader, 'MgRead-Android-Updater');
      final response = await request.close().timeout(_requestTimeout);
      if (response.statusCode != HttpStatus.ok) throw HttpException('Update HTTP ${response.statusCode}');
      final body = await _readBounded(response, _maxReleaseMetadataBytes).timeout(_requestTimeout);
      final release = _parseManifest(body);
      if (release == null) throw const FormatException('Invalid update manifest');
      final local = await _currentVersion();
      _timing.complete(now, success: true);
      if (local.platform != AppUpdatePlatform.android) return const UpdateCheckResult(UpdateCheckStatus.unsupported);
      return isRemoteAppUpgrade(release.version, local)
          ? UpdateCheckResult(UpdateCheckStatus.available, value: release)
          : const UpdateCheckResult(UpdateCheckStatus.upToDate);
    } on Object catch (error) {
      _timing.complete(now, success: false);
      return UpdateCheckResult(UpdateCheckStatus.failed, error: error);
    } finally {
      client?.close(force: true);
      await _saveTiming();
    }
  }

  Future<void> _loadTiming() async {
    if (_timingLoaded) return;
    _timingLoaded = true;
    try {
      final root = (await _supportDirectory()).path;
      final state = File('$root${Platform.pathSeparator}github-apk-update-state.json');
      if (await state.exists()) {
        _timing.restore((jsonDecode(await state.readAsString()) as Map).cast<String, Object?>());
      } else {
        final legacy = File('$root${Platform.pathSeparator}github-apk-update-check.txt');
        if (await legacy.exists()) _timing.succeededAt = DateTime.tryParse((await legacy.readAsString()).trim());
      }
    } on Object {
      /* Unavailable timing storage must not prevent checking. */
    }
  }

  Future<void> _saveTiming() async {
    try {
      final root = (await _supportDirectory()).path;
      final state = File('$root${Platform.pathSeparator}github-apk-update-state.json');
      await state.parent.create(recursive: true);
      await state.writeAsString(jsonEncode(_timing.toJson()), flush: true);
    } on Object {
      /* Retain the in-memory cadence when storage is unavailable. */
    }
  }

  /// Parses the `mgread.android-update.v1` asset uploaded with each GitHub Release.
  ///
  /// Required fields: schema, repository, version, buildNumber, tag,
  /// publishedAt, and apk.name/apk.sha256. APK and release URLs are derived
  /// from the fixed repository and tag to keep the manifest compact.
  GitHubApkRelease? _parseManifest(List<int> bytes) {
    try {
      final manifest = jsonDecode(utf8.decode(bytes));
      if (manifest is! Map<String, dynamic> ||
          manifest['schema'] != 'mgread.android-update.v1' ||
          manifest['repository'] != 'lingy-Mg/mg_read') {
        return null;
      }
      final versionText = manifest['version'];
      final buildNumber = manifest['buildNumber'];
      final tag = manifest['tag'];
      final apk = manifest['apk'];
      final publishedAt = DateTime.tryParse(manifest['publishedAt'] as String? ?? '');
      if (versionText is! String ||
          !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(versionText) ||
          buildNumber is! int ||
          buildNumber < 0 ||
          buildNumber > 2147483647 ||
          tag is! String ||
          tag != 'v$versionText+$buildNumber' ||
          apk is! Map<String, dynamic> ||
          publishedAt == null) {
        return null;
      }
      final version = AppVersionInfo(platform: AppUpdatePlatform.android, version: versionText, buildNumber: buildNumber);
      final apkName = githubAndroidApkAssetName(version);
      final sha256 = apk['sha256'];
      if (apk['name'] != apkName || sha256 is! String || !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(sha256)) return null;
      final apkUrl = Uri.parse('https://github.com/lingy-Mg/mg_read/releases/latest/download/${Uri.encodeComponent(apkName)}');
      final releaseUrl = Uri.parse('https://github.com/lingy-Mg/mg_read/releases/tag/${Uri.encodeComponent(tag)}');
      final tagUrl = Uri.parse('https://github.com/lingy-Mg/mg_read/tree/${Uri.encodeComponent(tag)}');
      final author = manifest['author'] is String ? manifest['author'] as String : 'unknown';
      final authorUrl = _githubUri(manifest['authorUrl']);
      final avatarUrl = _githubAvatarUri(manifest['authorAvatarUrl']);
      final releaseNotes = manifest['releaseNotes'] is String ? manifest['releaseNotes'] as String : '';
      final targetCommitish = manifest['targetCommitish'] is String ? manifest['targetCommitish'] as String : 'main';
      final commitShaValue = manifest['commitSha'];
      final commitSha = commitShaValue is String && RegExp(r'^[a-fA-F0-9]{40}$').hasMatch(commitShaValue)
          ? commitShaValue.toLowerCase()
          : null;
      final commitUrl = commitSha == null
          ? _githubUri(manifest['commitUrl'])
          : Uri.https('github.com', '/lingy-Mg/mg_read/commit/$commitSha');
      final compareUrl = _githubUri(manifest['compareUrl']);
      final createdAt = DateTime.tryParse(manifest['createdAt'] as String? ?? '');
      final assetSize = apk['size'] is int && (apk['size'] as int) > 0 ? apk['size'] as int : 0;
      final assets = <GitHubApkReleaseAsset>[
        GitHubApkReleaseAsset(
          name: apkName,
          downloadUrl: apkUrl,
          size: assetSize,
          downloadCount: 0,
          contentType: 'application/vnd.android.package-archive',
          createdAt: createdAt,
          updatedAt: createdAt,
        ),
      ];
      return GitHubApkRelease(
        version: version,
        apkUrl: apkUrl,
        apkName: apkName,
        sha256: sha256.toLowerCase(),
        repository: 'lingy-Mg/mg_read',
        title: manifest['title'] is String && (manifest['title'] as String).isNotEmpty ? manifest['title'] as String : tag,
        tag: tag,
        releaseUrl: releaseUrl,
        tagUrl: tagUrl,
        publishedAt: publishedAt,
        author: author,
        authorUrl: authorUrl,
        authorAvatarUrl: avatarUrl,
        targetCommitish: targetCommitish,
        releaseNotes: releaseNotes,
        assets: List<GitHubApkReleaseAsset>.unmodifiable(assets),
        releaseId: manifest['releaseId'] is int ? manifest['releaseId'] as int : null,
        createdAt: createdAt,
        commitSha: commitSha,
        commitUrl: commitUrl,
        compareUrl: compareUrl,
      );
    } on Object {
      return null;
    }
  }
}

Uri? _githubUri(Object? value) {
  if (value is! String) return null;
  final uri = Uri.tryParse(value);
  if (uri == null || uri.scheme != 'https' || uri.host != 'github.com') return null;
  return uri;
}

Uri? _githubAvatarUri(Object? value) {
  if (value is! String) return null;
  final uri = Uri.tryParse(value);
  if (uri == null || uri.scheme != 'https' || uri.host != 'avatars.githubusercontent.com') return null;
  return uri;
}

Future<List<int>> _readBounded(HttpClientResponse response, int limit) async {
  final output = BytesBuilder(copy: false);
  var length = 0;
  await for (final chunk in response.timeout(_requestTimeout)) {
    length += chunk.length;
    if (length > limit) throw const FormatException('github_release_metadata_too_large');
    output.add(chunk);
  }
  return output.takeBytes();
}
