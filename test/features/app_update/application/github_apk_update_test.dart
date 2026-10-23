import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/features/app_update/application/github_apk_update.dart';
import 'package:mg_read/features/lan_sync/domain/app_update_models.dart';

void main() {
  final release = GitHubApkRelease(
    version: AppVersionInfo(platform: AppUpdatePlatform.android, version: '0.10.18', buildNumber: 388),
    apkUrl: Uri(scheme: 'https', host: 'github.com', path: '/lingy-Mg/mg_read/releases/download/v0.10.18+388/MgRead.apk'),
    apkName: 'MgRead-v0.10.18+388-android-arm64.apk',
    sha256: 'sha256-test',
    repository: 'lingy-Mg/mg_read',
    title: 'MgRead v0.10.18+388',
    tag: 'v0.10.18+388',
    releaseUrl: Uri(scheme: 'https', host: 'github.com', path: '/lingy-Mg/mg_read/releases/tag/v0.10.18+388'),
    tagUrl: Uri(scheme: 'https', host: 'github.com', path: '/lingy-Mg/mg_read/tree/v0.10.18+388'),
    publishedAt: DateTime.utc(2026, 10, 2, 10, 30),
    author: 'github-actions',
    targetCommitish: 'main',
    releaseNotes: '修复阅读器章节跳转。\n优化书架加载。',
    assets: <GitHubApkReleaseAsset>[
      GitHubApkReleaseAsset(
        name: 'MgRead.apk',
        downloadUrl: Uri(scheme: 'https', host: 'github.com', path: '/download/MgRead.apk'),
        size: 1234,
        downloadCount: 10,
        contentType: 'application/vnd.android.package-archive',
      ),
    ],
    releaseId: 123,
    createdAt: DateTime.utc(2026, 10, 2, 10, 20),
    commitSha: 'd98f6d75d4cfb82b49ccb9506948b09b851ce58f',
    commitUrl: Uri(scheme: 'https', host: 'github.com', path: '/lingy-Mg/mg_read/commit/d98f6d75d4cfb82b49ccb9506948b09b851ce58f'),
    compareUrl: Uri(scheme: 'https', host: 'github.com', path: '/lingy-Mg/mg_read/compare/v0.10.16+386...v0.10.18+388'),
    checksumUrl: Uri(scheme: 'https', host: 'github.com', path: '/download/SHA256SUMS.txt'),
  );

  test('serializes release metadata as structured JSON', () {
    final json = release.toJson();

    expect(json['schema'], 'mgread.github-release.v1');
    expect(json['version'], '0.10.18 (388)');
    expect(json['publishedAt'], '2026-10-02T10:30:00.000Z');
    expect(json['author'], 'github-actions');
    expect(json['commitSha'], 'd98f6d75d4cfb82b49ccb9506948b09b851ce58f');
    expect((json['apk']! as Map<String, Object?>)['sha256'], 'sha256-test');
    expect((json['assets']! as List<Object?>).single, containsPair('downloadCount', 10));
  });

  test('formats each release field on its own line and separates notes by two newlines', () {
    final log = release.toLogText();
    final sections = log.split('\n\n');

    expect(sections, hasLength(2));
    expect(sections.first, contains('版本: 0.10.18 (388)'));
    expect(sections.first, contains('发布时间: 2026-10-02T10:30:00.000Z'));
    expect(sections.first, contains('提交 SHA: d98f6d75d4cfb82b49ccb9506948b09b851ce58f'));
    expect(sections.last, '修复阅读器章节跳转。\n优化书架加载。');
  });
}
