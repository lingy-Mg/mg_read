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
const String githubApkUpdateManifestUrl = 'https://github.com/lingy-Mg/mg_read/releases/latest/download/update.json';
const int _maxReleaseMetadataBytes = 256 * 1024;
const Duration _requestTimeout = Duration(seconds: 12);

bool isGitHubApkUpdateCheckDue(DateTime? lastCheck, DateTime now) =>
    lastCheck == null || now.difference(lastCheck) >= githubApkUpdateCheckInterval;

String githubAndroidApkAssetName(AppVersionInfo version) =>
    'MgRead-${version.version}${version.buildNumber > 0 ? '+${version.buildNumber}' : ''}-android-arm64.apk';

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
    Uri? manifestUri,
    bool? isAndroid,
  }) : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       _clock = clock ?? DateTime.now,
       _httpClientFactory = httpClientFactory ?? HttpClient.new,
       _manifestUri = manifestUri ?? Uri.parse(githubApkUpdateManifestUrl),
       _isAndroid = isAndroid ?? Platform.isAndroid;

  final Future<AppVersionInfo> Function() _currentVersion;
  final Future<void> Function(GitHubApkRelease release) _downloadAndInstall;
  final Future<Directory> Function() _supportDirectory;
  final DateTime Function() _clock;
  final HttpClient Function() _httpClientFactory;
  final Uri _manifestUri;
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
      final request = await client.getUrl(_manifestUri).timeout(_requestTimeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      request.headers.set(HttpHeaders.userAgentHeader, 'MgRead-Android-Updater');
      final response = await request.close().timeout(_requestTimeout);
      if (response.statusCode != HttpStatus.ok) return null;
      final body = await _readBounded(response, _maxReleaseMetadataBytes);
      final release = _parseManifest(body);
      if (release == null) return null;
      final local = await _currentVersion();
      if (local.platform != AppUpdatePlatform.android || !isRemoteAppUpgrade(release.version, local)) return null;
      return release;
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
