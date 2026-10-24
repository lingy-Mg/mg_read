/// User confirmation surface for a newer Android APK.
///
/// The app shell owns when this prompt is shown; this file owns only the
/// release notes, link to this version's GitHub Release, and the user's
/// install-or-later choice.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:mg_read/features/app_update/application/github_apk_update.dart';

Future<bool?> showGitHubApkUpdatePrompt(
  BuildContext context,
  GitHubApkRelease release, {
  Future<bool> Function(Uri uri)? openReleasePage,
}) => showDialog<bool>(
  context: context,
  barrierDismissible: false,
  builder: (context) => AlertDialog(
    key: const Key('github-apk-update-prompt'),
    title: const Text('发现新版本'),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560, maxHeight: 520),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('更新内容', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            SelectableText(
              _releaseNotesForPrompt(release.releaseNotes),
              key: const Key('github-apk-update-release-notes'),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.5),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              key: const Key('github-apk-update-release-link'),
              onPressed: () async {
                final open = openReleasePage ?? _openReleasePage;
                await open(release.releaseUrl);
              },
              icon: const Icon(Icons.open_in_new),
              label: const Text('在 GitHub 查看此版本'),
            ),
          ],
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

String _releaseNotesForPrompt(String releaseNotes) {
  final lines = releaseNotes.trim().split(RegExp(r'\r?\n'));
  if (lines.isNotEmpty && lines.first.startsWith('MgRead ') && lines.first.endsWith('更新内容')) {
    lines.removeAt(0);
  }
  return lines.where((line) => !line.startsWith('完整提交范围：')).join('\n').trim();
}

Future<bool> _openReleasePage(Uri uri) => launchUrl(uri, mode: LaunchMode.externalApplication);

Future<void> showGitHubApkUpdateInstallProgress(
  BuildContext context,
  Future<void> Function(GitHubApkDownloadProgressCallback onProgress) install,
) async {
  final result = await showDialog<_ApkUpdateProgressResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _GitHubApkUpdateProgressDialog(install: install),
  );
  if (result case _ApkUpdateProgressFailure(:final error, :final stackTrace)) {
    Error.throwWithStackTrace(error, stackTrace);
  }
}

sealed class _ApkUpdateProgressResult {
  const _ApkUpdateProgressResult();
}

final class _ApkUpdateProgressSuccess extends _ApkUpdateProgressResult {
  const _ApkUpdateProgressSuccess();
}

final class _ApkUpdateProgressFailure extends _ApkUpdateProgressResult {
  const _ApkUpdateProgressFailure(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;
}

class _GitHubApkUpdateProgressDialog extends StatefulWidget {
  const _GitHubApkUpdateProgressDialog({required this.install});

  final Future<void> Function(GitHubApkDownloadProgressCallback onProgress) install;

  @override
  State<_GitHubApkUpdateProgressDialog> createState() => _GitHubApkUpdateProgressDialogState();
}

class _GitHubApkUpdateProgressDialogState extends State<_GitHubApkUpdateProgressDialog> {
  GitHubApkDownloadProgress? _progress;
  GitHubApkDownloadProgress? _pendingProgress;
  Timer? _progressTimer;
  DateTime? _lastPaintAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_install()));
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    super.dispose();
  }

  Future<void> _install() async {
    _ApkUpdateProgressResult result;
    try {
      await widget.install(_onProgress);
      result = const _ApkUpdateProgressSuccess();
    } on Object catch (error, stackTrace) {
      result = _ApkUpdateProgressFailure(error, stackTrace);
    }
    if (mounted) Navigator.of(context).pop(result);
  }

  void _onProgress(GitHubApkDownloadProgress progress) {
    if (!mounted) return;
    _pendingProgress = progress;
    final now = DateTime.now();
    final isComplete = progress.totalBytes > 0 && progress.receivedBytes >= progress.totalBytes;
    if (_lastPaintAt == null || isComplete || now.difference(_lastPaintAt!) >= const Duration(milliseconds: 120)) {
      _progressTimer?.cancel();
      _progressTimer = null;
      setState(() {
        _progress = progress;
        _pendingProgress = null;
      });
      _lastPaintAt = now;
    } else {
      _progressTimer ??= Timer(const Duration(milliseconds: 120), () {
        if (!mounted || _pendingProgress == null) return;
        setState(() {
          _progress = _pendingProgress;
          _pendingProgress = null;
        });
        _lastPaintAt = DateTime.now();
        _progressTimer = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = _progress;
    final fraction = progress?.fraction;
    return PopScope(
      canPop: false,
      child: Dialog.fullscreen(
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const Icon(Icons.downloading_rounded, size: 48),
                    const SizedBox(height: 20),
                    Text('正在下载更新', style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
                    const SizedBox(height: 24),
                    LinearProgressIndicator(value: fraction),
                    const SizedBox(height: 12),
                    Text(
                      progress == null
                          ? '正在连接 GitHub…'
                          : fraction == null
                          ? '已下载 ${_formatApkBytes(progress.receivedBytes)}'
                          : '${(fraction * 100).round()}%  ·  ${_formatApkBytes(progress.receivedBytes)} / ${_formatApkBytes(progress.totalBytes)}',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 16),
                    Text('下载完成后将打开系统安装器，请稍候。', textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _formatApkBytes(int bytes) {
  const bytesPerMegabyte = 1024 * 1024;
  if (bytes < bytesPerMegabyte) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / bytesPerMegabyte).toStringAsFixed(1)} MB';
}
