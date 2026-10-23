/// Android-only GitHub Release update discovery and install orchestration.
///
/// Checks are initiated by the app shell after its first frame. A small marker
/// in application support storage limits checks across cold starts. Release
/// assets are bounded, SHA-256 verified, and passed to Android's Package
/// Installer; the system remains responsible for signing and user confirmation.
library;

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
const String _releaseApiUrl = 'https://api.github.com/repos/lingy-Mg/mg_read/releases/latest';
const int _maxReleaseMetadataBytes = 256 * 1024;
const int _maxChecksumFileBytes = 32 * 1024;
const Duration _requestTimeout = Duration(seconds: 12);

bool isGitHubApkUpdateCheckDue(DateTime? lastCheck, DateTime now) =>
    lastCheck == null || now.difference(lastCheck) >= githubApkUpdateCheckInterval;

final githubApkUpdateCoordinatorProvider = Provider<GitHubApkUpdateCoordinator>((ref) {
  final service = ref.watch(appUpdateServiceProvider);
  return GitHubApkUpdateCoordinator(
    currentVersion: service.currentVersion,
    downloadAndInstall: (release) async {
      await service.ensureInstallPermission();
      final prepared = await release.download();
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
    'targetCommitish': targetCommitish,
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
      '目标提交: $targetCommitish',
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

  Future<PreparedAppPackage> download({HttpClient? client, Future<Directory> Function()? temporaryDirectory}) async {
    final http = client ?? HttpClient();
    final ownsClient = client == null;
    final temporary = await (temporaryDirectory ?? getTemporaryDirectory)();
    final directory = await temporary.createTemp('mgread-github-update-');
    final file = File('${directory.path}${Platform.pathSeparator}$apkName');
    try {
      final request = await http.getUrl(apkUrl).timeout(_requestTimeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/octet-stream');
      request.headers.set(HttpHeaders.userAgentHeader, 'MgRead-Android-Updater');
      final response = await request.close().timeout(_requestTimeout);
      if (response.statusCode != HttpStatus.ok) throw const HttpException('github_apk_download_failed');
      final declaredLength = response.contentLength;
      if (declaredLength <= 0 || declaredLength > appUpdateMaxPackageBytes) {
        throw const FormatException('github_apk_size_invalid');
      }
      final sink = file.openWrite();
      final digestSink = _DigestSink();
      final hashSink = crypto.sha256.startChunkedConversion(digestSink);
      var byteCount = 0;
      final checksum = LanSyncChecksumSink();
      try {
        await for (final chunk in response.timeout(_requestTimeout)) {
          byteCount += chunk.length;
          if (byteCount > appUpdateMaxPackageBytes) throw const FormatException('github_apk_size_invalid');
          sink.add(chunk);
          hashSink.add(chunk);
          checksum.add(chunk);
        }
      } finally {
        await sink.close();
        hashSink.close();
      }
      if (byteCount != declaredLength || digestSink.value != sha256) throw const FormatException('github_apk_hash_mismatch');
      return PreparedAppPackage(
        descriptor: AppPackageDescriptor(version: version, bytes: byteCount, checksum: checksum.close(), fileName: apkName),
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
    bool? isAndroid,
  }) : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       _clock = clock ?? DateTime.now,
       _httpClientFactory = httpClientFactory ?? HttpClient.new,
       _isAndroid = isAndroid ?? Platform.isAndroid;

  final Future<AppVersionInfo> Function() _currentVersion;
  final Future<void> Function(GitHubApkRelease release) _downloadAndInstall;
  final Future<Directory> Function() _supportDirectory;
  final DateTime Function() _clock;
  final HttpClient Function() _httpClientFactory;
  final bool _isAndroid;
  Future<GitHubApkRelease?>? _checkInFlight;
  Future<void>? _installInFlight;

  Future<GitHubApkRelease?> checkForUpdate() {
    if (!_isAndroid) return Future<GitHubApkRelease?>.value();
    return _checkInFlight ??= _check().whenComplete(() => _checkInFlight = null);
  }

  Future<void> install(GitHubApkRelease release) {
    if (!_isAndroid) return Future<void>.value();
    return _installInFlight ??= _downloadAndInstall(release).whenComplete(() => _installInFlight = null);
  }

  Future<GitHubApkRelease?> _check() async {
    final marker = await _checkMarker();
    final now = _clock();
    if (!isGitHubApkUpdateCheckDue(marker, now)) return null;
    await _writeMarker(now);

    final client = _httpClientFactory();
    try {
      final request = await client.getUrl(Uri.parse(_releaseApiUrl)).timeout(_requestTimeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      request.headers.set(HttpHeaders.userAgentHeader, 'MgRead-Android-Updater');
      final response = await request.close().timeout(_requestTimeout);
      if (response.statusCode != HttpStatus.ok) return null;
      final body = await _readBounded(response, _maxReleaseMetadataBytes);
      final release = _parseRelease(body);
      if (release == null) return null;
      final local = await _currentVersion();
      if (local.platform != AppUpdatePlatform.android || !isRemoteAppUpgrade(release.version, local)) return null;
      final commitSha = release.commitSha ?? await _resolveCommitSha(client, release.tag);
      final checksumUrl = release.checksumUrl;
      if (checksumUrl == null) return null;
      final checksumRequest = await client.getUrl(checksumUrl).timeout(_requestTimeout);
      checksumRequest.headers.set(HttpHeaders.userAgentHeader, 'MgRead-Android-Updater');
      final checksumResponse = await checksumRequest.close().timeout(_requestTimeout);
      if (checksumResponse.statusCode != HttpStatus.ok) return null;
      final checksums = utf8.decode(await _readBounded(checksumResponse, _maxChecksumFileBytes));
      final expectedHash = _readExpectedSha256(checksums, release.apkName);
      if (expectedHash == null) return null;
      return GitHubApkRelease(
        version: release.version,
        apkUrl: release.apkUrl,
        apkName: release.apkName,
        sha256: expectedHash,
        repository: release.repository,
        title: release.title,
        tag: release.tag,
        releaseUrl: release.releaseUrl,
        tagUrl: release.tagUrl,
        publishedAt: release.publishedAt,
        author: release.author,
        targetCommitish: release.targetCommitish,
        releaseNotes: release.releaseNotes,
        assets: release.assets,
        releaseId: release.releaseId,
        createdAt: release.createdAt,
        commitSha: commitSha,
        commitUrl: commitSha == null ? release.commitUrl : Uri.https('github.com', '/lingy-Mg/mg_read/commit/$commitSha'),
        compareUrl: release.compareUrl,
        checksumUrl: release.checksumUrl,
      );
    } on Object {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<DateTime?> _checkMarker() async {
    try {
      final marker = File('${(await _supportDirectory()).path}${Platform.pathSeparator}github-apk-update-check.txt');
      if (!await marker.exists()) return null;
      return DateTime.tryParse((await marker.readAsString()).trim());
    } on Object {
      return null;
    }
  }

  Future<void> _writeMarker(DateTime at) async {
    try {
      final marker = File('${(await _supportDirectory()).path}${Platform.pathSeparator}github-apk-update-check.txt');
      await marker.parent.create(recursive: true);
      await marker.writeAsString(at.toUtc().toIso8601String(), flush: true);
    } on Object {
      // A read-only or unavailable marker must never block app startup.
    }
  }

  GitHubApkRelease? _parseRelease(List<int> bytes) {
    try {
      final release = jsonDecode(utf8.decode(bytes));
      if (release is! Map<String, dynamic> || release['draft'] == true || release['prerelease'] == true) return null;
      final tag = release['tag_name'];
      final assets = release['assets'];
      if (tag is! String || assets is! List<dynamic>) return null;
      final versionMatch = RegExp(r'^v(\d+\.\d+\.\d+)(?:\+(\d+))?$').firstMatch(tag);
      if (versionMatch == null) return null;
      final version = AppVersionInfo(
        platform: AppUpdatePlatform.android,
        version: versionMatch.group(1)!,
        buildNumber: int.tryParse(versionMatch.group(2) ?? '') ?? 0,
      );
      final apkName = 'MgRead-$tag-android-arm64.apk';
      Map<String, dynamic>? apk;
      Map<String, dynamic>? checksums;
      final releaseAssets = <GitHubApkReleaseAsset>[];
      for (final asset in assets.whereType<Map<String, dynamic>>()) {
        if (asset['name'] == apkName) apk = asset;
        if (asset['name'] == 'SHA256SUMS.txt') checksums = asset;
        final name = asset['name'];
        final downloadUrl = _githubUri(asset['browser_download_url']);
        if (name is String && downloadUrl != null) {
          releaseAssets.add(
            GitHubApkReleaseAsset(
              name: name,
              downloadUrl: downloadUrl,
              size: asset['size'] is int ? asset['size'] as int : 0,
              downloadCount: asset['download_count'] is int ? asset['download_count'] as int : 0,
              contentType: asset['content_type'] is String ? asset['content_type'] as String : '',
              createdAt: DateTime.tryParse(asset['created_at'] as String? ?? ''),
              updatedAt: DateTime.tryParse(asset['updated_at'] as String? ?? ''),
            ),
          );
        }
      }
      if (apk == null || checksums == null) return null;
      final apkUrl = _githubUri(apk['browser_download_url']);
      final checksumUrl = _githubUri(checksums['browser_download_url']);
      final releaseUrl = _githubUri(release['html_url']);
      final publishedAt = DateTime.tryParse(release['published_at'] as String? ?? '');
      if (apkUrl == null || checksumUrl == null || releaseUrl == null || publishedAt == null) return null;
      final authorRecord = release['author'];
      final authorName = authorRecord is Map<String, dynamic> ? authorRecord['login'] : null;
      final releaseNotes = release['body'] is String ? release['body'] as String : '';
      final compareMatch = RegExp(r'https://github\.com/lingy-Mg/mg_read/compare/[^\s)]+').firstMatch(releaseNotes);
      final targetCommitish = release['target_commitish'] is String ? release['target_commitish'] as String : '';
      final targetSha = RegExp(r'^[a-fA-F0-9]{40}$').hasMatch(targetCommitish) ? targetCommitish.toLowerCase() : null;
      return GitHubApkRelease(
        version: version,
        apkUrl: apkUrl,
        apkName: apkName,
        sha256: '',
        repository: 'lingy-Mg/mg_read',
        title: release['name'] is String && (release['name'] as String).isNotEmpty ? release['name'] as String : tag,
        tag: tag,
        releaseUrl: releaseUrl,
        tagUrl: Uri.https('github.com', '/lingy-Mg/mg_read/tree/${Uri.encodeComponent(tag)}'),
        publishedAt: publishedAt,
        author: authorName is String ? authorName : 'unknown',
        targetCommitish: targetCommitish,
        releaseNotes: releaseNotes,
        assets: List<GitHubApkReleaseAsset>.unmodifiable(releaseAssets),
        releaseId: release['id'] is int ? release['id'] as int : null,
        createdAt: DateTime.tryParse(release['created_at'] as String? ?? ''),
        commitSha: targetSha,
        commitUrl: targetSha == null ? null : Uri.https('github.com', '/lingy-Mg/mg_read/commit/$targetSha'),
        compareUrl: compareMatch == null ? null : Uri.tryParse(compareMatch.group(0)!),
        checksumUrl: checksumUrl,
      );
    } on Object {
      return null;
    }
  }
}

Future<String?> _resolveCommitSha(HttpClient client, String tag) async {
  try {
    final request = await client.getUrl(Uri.https('api.github.com', '/repos/lingy-Mg/mg_read/commits/$tag')).timeout(_requestTimeout);
    request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
    request.headers.set(HttpHeaders.userAgentHeader, 'MgRead-Android-Updater');
    final response = await request.close().timeout(_requestTimeout);
    if (response.statusCode != HttpStatus.ok) return null;
    final decoded = jsonDecode(utf8.decode(await _readBounded(response, 16 * 1024)));
    if (decoded is! Map<String, dynamic>) return null;
    final sha = decoded['sha'];
    return sha is String && RegExp(r'^[a-fA-F0-9]{40}$').hasMatch(sha) ? sha.toLowerCase() : null;
  } on Object {
    return null;
  }
}

Uri? _githubUri(Object? value) {
  if (value is! String) return null;
  final uri = Uri.tryParse(value);
  if (uri == null || uri.scheme != 'https' || uri.host != 'github.com') return null;
  return uri;
}

String? _readExpectedSha256(String contents, String fileName) {
  for (final line in contents.split(RegExp(r'\r?\n'))) {
    final match = RegExp(r'^([a-fA-F0-9]{64})\s+\*?(.+)$').firstMatch(line.trim());
    if (match != null && match.group(2) == fileName) return match.group(1)!.toLowerCase();
  }
  return null;
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
