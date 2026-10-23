/// User confirmation surface for a newer Android APK.
///
/// The app shell owns when this prompt is shown; this file owns only the
/// structured release log and the user's install-or-later choice.
library;

import 'package:flutter/material.dart';
import 'package:mg_read/features/app_update/application/github_apk_update.dart';

Future<bool?> showGitHubApkUpdatePrompt(BuildContext context, GitHubApkRelease release) => showDialog<bool>(
  context: context,
  barrierDismissible: false,
  builder: (context) => AlertDialog(
    key: const Key('github-apk-update-prompt'),
    title: const Text('发现新版本'),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560, maxHeight: 520),
      child: SingleChildScrollView(
        child: SelectableText(
          release.toLogText(),
          key: const Key('github-apk-update-release-log'),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: 'monospace', height: 1.45),
        ),
      ),
    ),
    actions: <Widget>[
      TextButton(key: const Key('github-apk-update-later'), onPressed: () => Navigator.of(context).pop(false), child: const Text('稍后')),
      FilledButton(
        key: const Key('github-apk-update-install'),
        onPressed: () => Navigator.of(context).pop(true),
        child: const Text('下载安装'),
      ),
    ],
  ),
);
