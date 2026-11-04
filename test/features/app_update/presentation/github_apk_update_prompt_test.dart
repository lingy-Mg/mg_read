/// Covers the user-facing content and GitHub link in the APK update prompt.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/app/app_tv_theme.dart';
import 'package:mg_read/features/app_update/application/github_apk_update.dart';
import 'package:mg_read/features/app_update/presentation/github_apk_update_prompt.dart';
import 'package:mg_read/features/app_update/presentation/github_apk_update_tv_prompt.dart';
import 'package:mg_read/features/lan_sync/domain/app_update_models.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';

void main() {
  final releaseUrl = Uri.https('github.com', '/lingy-Mg/mg_read/releases/tag/v0.10.42+412');
  final release = GitHubApkRelease(
    version: const AppVersionInfo(platform: AppUpdatePlatform.android, version: '0.10.42', buildNumber: 412),
    apkUrl: Uri.https('github.com', '/download/MgRead.apk'),
    apkName: 'MgRead-0.10.42+412-android-arm64.apk',
    sha256: 'aabbcc',
    repository: 'lingy-Mg/mg_read',
    title: 'MgRead v0.10.42+412',
    tag: 'v0.10.42+412',
    releaseUrl: releaseUrl,
    tagUrl: Uri.https('github.com', '/lingy-Mg/mg_read/tree/v0.10.42+412'),
    publishedAt: DateTime.utc(2026, 10, 24),
    author: 'github-actions',
    targetCommitish: 'main',
    releaseNotes: 'MgRead v0.10.42+412 更新内容\n\n问题修复\n- 修复书架加载\n\n完整提交范围：$releaseUrl',
    assets: const <GitHubApkReleaseAsset>[],
  );

  for (final size in [const Size(1280, 720), const Size(640, 360)]) {
    testWidgets('TV update prompt initially focuses later and reaches install by remote at $size', (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      bool? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: appTvTheme(AppTheme.dark()),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.6)),
            child: TvModeScope(
              enabled: true,
              onChanged: (_) {},
              child: TvRemoteShortcuts(child: child!),
            ),
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showGitHubApkUpdatePrompt(context, release);
                },
                child: const Text('Show'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Show'));
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TvFocusable>()?.key,
        const Key('github-apk-update-later'),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TvFocusable>()?.key,
        const Key('github-apk-update-install'),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(result, isTrue);
      expect(find.byKey(const Key('github-apk-update-prompt')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('shows only release notes and opens this version on GitHub', (tester) async {
    Uri? openedRelease;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              key: const Key('show-update-prompt'),
              onPressed: () => showGitHubApkUpdatePrompt(
                context,
                release,
                openReleasePage: (uri) async {
                  openedRelease = uri;
                  return true;
                },
              ),
              child: const Text('Show'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('show-update-prompt')));
    await tester.pumpAndSettle();

    expect(find.text('发现新版本'), findsOneWidget);
    expect(find.text('更新内容'), findsOneWidget);
    expect(find.byKey(const Key('github-apk-update-release-notes')), findsOneWidget);
    final notes = tester.widget<SelectableText>(find.byKey(const Key('github-apk-update-release-notes')));
    expect(notes.data, '问题修复\n- 修复书架加载');
    expect(notes.data, isNot(contains('APK')));
    expect(notes.data, isNot(contains('SHA-256')));
    expect(notes.data, isNot(contains('完整提交范围')));

    await tester.tap(find.byKey(const Key('github-apk-update-release-link')));
    await tester.pumpAndSettle();

    expect(openedRelease, release.releaseUrl);
    expect(find.byKey(const Key('github-apk-update-prompt')), findsOneWidget);
  });

  for (final disableAnimations in [false, true]) {
    testWidgets('TV long release notes scroll with disableAnimations=$disableAnimations while actions remain reachable', (tester) async {
      await tester.binding.setSurfaceSize(const Size(640, 360));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: appTvTheme(AppTheme.dark()),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.6), disableAnimations: disableAnimations),
            child: TvModeScope(
              enabled: true,
              onChanged: (_) {},
              child: TvRemoteShortcuts(child: child!),
            ),
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => GitHubApkUpdateTvPrompt(
                    notes: List.generate(80, (i) => '第 $i 项：修复电视遥控操作和页面显示。').join('\n'),
                    onOpenRelease: () {},
                    onLater: () {},
                    onInstall: () {},
                  ),
                ),
                child: const Text('Show'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Show'));
      await tester.pumpAndSettle();
      final notes = find.byKey(const Key('github-apk-update-notes-scroll'));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      final focus = Focus.of(tester.element(notes));
      expect(FocusManager.instance.primaryFocus, focus);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      final scrollable = find.descendant(of: notes, matching: find.byType(Scrollable)).first;
      expect(tester.state<ScrollableState>(scrollable).position.pixels, greaterThan(0));
      expect(FocusManager.instance.primaryFocus, focus);
      expect(find.byKey(const Key('github-apk-update-install')).hitTestable(), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TvFocusable>(), isNotNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('download progress is full-screen, reports progress, and blocks back dismissal', (tester) async {
    final finishDownload = Completer<void>();

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              key: const Key('start-update-install'),
              onPressed: () => showGitHubApkUpdateInstallProgress(context, (onProgress) async {
                onProgress(const GitHubApkDownloadProgress(receivedBytes: 25, totalBytes: 100));
                await finishDownload.future;
              }),
              child: const Text('Install'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('start-update-install')));
    await tester.pump();
    await tester.pump();

    expect(find.text('正在下载更新'), findsOneWidget);
    expect(find.textContaining('25%'), findsOneWidget);
    final progressIndicator = tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
    expect(progressIndicator.value, 0.25);
    expect(find.text('取消'), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('正在下载更新'), findsOneWidget);

    finishDownload.complete();
    await tester.pumpAndSettle();
    expect(find.text('正在下载更新'), findsNothing);
  });
}
