/// Verifies APK-only update cadence and bounded, SHA-256 verified downloads.
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/app_update/application/github_apk_update.dart';
import 'package:mg_read/features/lan_sync/domain/app_update_models.dart';

GitHubApkRelease _release({required Uri apkUrl, required String apkName, required String sha256}) => GitHubApkRelease(
  version: const AppVersionInfo(platform: AppUpdatePlatform.android, version: '1.2.3', buildNumber: 4),
  apkUrl: apkUrl,
  apkName: apkName,
  sha256: sha256,
  repository: 'lingy-Mg/mg_read',
  title: 'MgRead v1.2.3+4',
  tag: 'v1.2.3+4',
  releaseUrl: Uri.https('github.com', '/lingy-Mg/mg_read/releases/tag/v1.2.3%2B4'),
  tagUrl: Uri.https('github.com', '/lingy-Mg/mg_read/tree/v1.2.3%2B4'),
  publishedAt: DateTime.utc(2026, 10, 23),
  author: 'release-bot',
  targetCommitish: 'main',
  releaseNotes: '',
  assets: const <GitHubApkReleaseAsset>[],
);

void main() {
  test('startup checks become due at the 30 minute boundary', () {
    final checkedAt = DateTime.utc(2026, 10, 23, 10);

    expect(isGitHubApkUpdateCheckDue(null, checkedAt), isTrue);
    expect(isGitHubApkUpdateCheckDue(checkedAt, checkedAt.add(const Duration(minutes: 29, seconds: 59))), isFalse);
    expect(isGitHubApkUpdateCheckDue(checkedAt, checkedAt.add(const Duration(minutes: 30))), isTrue);
  });

  test('release APK asset name follows the GitHub workflow without the tag prefix', () {
    expect(
      githubAndroidApkAssetName(const AppVersionInfo(platform: AppUpdatePlatform.android, version: '0.10.23', buildNumber: 393)),
      'MgRead-0.10.23+393-android-arm64.apk',
    );
  });

  test('non-Android platforms never read app version or check GitHub', () async {
    var currentVersionRead = false;
    final coordinator = GitHubApkUpdateCoordinator(
      currentVersion: () async {
        currentVersionRead = true;
        return const AppVersionInfo(platform: AppUpdatePlatform.windows, version: '1.0.0', buildNumber: 1);
      },
      downloadAndInstall: (_) async {},
      isAndroid: false,
    );

    expect(await coordinator.checkForUpdate(), isNull);
    expect(currentVersionRead, isFalse);
  });

  test('manual check bypasses the startup interval and refreshes its marker', () async {
    final support = await Directory.systemTemp.createTemp('mgread-update-marker-test-');
    final marker = File('${support.path}${Platform.pathSeparator}github-apk-update-check.txt');
    final now = DateTime.utc(2026, 10, 23, 10, 15);
    await marker.writeAsString(now.toIso8601String());
    var requests = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final served = server.listen((request) async {
      requests++;
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
    });
    addTearDown(() async {
      await server.close(force: true);
      await served.cancel();
      if (await support.exists()) await support.delete(recursive: true);
    });
    final coordinator = GitHubApkUpdateCoordinator(
      currentVersion: () async => const AppVersionInfo(platform: AppUpdatePlatform.android, version: '1.0.0', buildNumber: 1),
      downloadAndInstall: (_) async {},
      supportDirectory: () async => support,
      clock: () => now.add(const Duration(minutes: 5)),
      manifestUri: Uri.parse('http://${server.address.address}:${server.port}/manifest'),
      isAndroid: true,
    );

    expect(await coordinator.checkForUpdate(), isNull);
    expect(requests, 0);
    expect(await coordinator.checkForUpdate(force: true), isNull);
    expect(requests, 1);
    expect(await marker.readAsString(), now.add(const Duration(minutes: 5)).toIso8601String());
  });

  test('APK download verifies release SHA-256 and exposes a bounded installer package', () async {
    final bytes = <int>[1, 2, 3, 4, 5];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final served = server.forEach((request) async {
      request.response.headers.contentLength = bytes.length;
      request.response.add(bytes);
      await request.response.close();
    });
    final temporary = await Directory.systemTemp.createTemp('mgread-github-apk-test-');
    addTearDown(() async {
      await server.close(force: true);
      await served;
      if (await temporary.exists()) await temporary.delete(recursive: true);
    });
    final apkName = 'MgRead-1.2.3+4-android-arm64.apk';
    final release = _release(
      apkUrl: Uri.parse('http://${server.address.address}:${server.port}/apk'),
      apkName: apkName,
      sha256: sha256.convert(bytes).toString(),
    );

    final prepared = await release.download(temporaryDirectory: () async => temporary);
    expect(await prepared.file.readAsBytes(), bytes);
    expect(prepared.descriptor.version.buildNumber, 4);
    expect(prepared.descriptor.bytes, bytes.length);
    await prepared.close();
    expect(await File('${temporary.path}${Platform.pathSeparator}${prepared.descriptor.fileName}').exists(), isFalse);
  });

  test('APK download rejects a mismatch with the release checksum', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.contentLength = 3;
      request.response.add(<int>[9, 8, 7]);
      await request.response.close();
    });
    final temporary = await Directory.systemTemp.createTemp('mgread-github-apk-bad-test-');
    addTearDown(() async {
      await server.close(force: true);
      if (await temporary.exists()) await temporary.delete(recursive: true);
    });
    final release = _release(
      apkUrl: Uri.parse('http://${server.address.address}:${server.port}/apk'),
      apkName: 'MgRead-1.2.3+4-android-arm64.apk',
      sha256: '0' * 64,
    );

    await expectLater(release.download(temporaryDirectory: () async => temporary), throwsFormatException);
    expect(await temporary.list().isEmpty, isTrue);
  });
}
