/// Local update metadata for dialog and navigation tests; never downloads an APK.
library;

import 'package:mg_read/features/app_update/application/github_apk_update.dart';
import 'package:mg_read/features/lan_sync/domain/app_update_models.dart';

final githubApkReleaseFixture = GitHubApkRelease(
  version: const AppVersionInfo(platform: AppUpdatePlatform.android, version: '0.10.42', buildNumber: 412),
  apkUrl: Uri.https('github.com', '/download/MgRead.apk'),
  apkName: 'MgRead-0.10.42+412-android-arm64.apk',
  sha256: 'aabbcc',
  repository: 'lingy-Mg/mg_read',
  title: 'MgRead v0.10.42+412',
  tag: 'v0.10.42+412',
  releaseUrl: Uri.https('github.com', '/lingy-Mg/mg_read/releases/tag/v0.10.42+412'),
  tagUrl: Uri.https('github.com', '/lingy-Mg/mg_read/tree/v0.10.42+412'),
  publishedAt: DateTime.utc(2026, 10, 24),
  author: 'github-actions',
  targetCommitish: 'main',
  releaseNotes: 'MgRead v0.10.42+412 更新内容\n\n问题修复\n- 修复书架加载\n\n完整提交范围：fixture',
  assets: const <GitHubApkReleaseAsset>[],
);
