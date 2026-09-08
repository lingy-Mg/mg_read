/// 媒体播放器封面入场测试。
///
/// 职责：
/// - 验证音频/视频准备阶段立即显示本地封面与加载反馈。
/// - 验证真实媒体就绪后只移除封面层，不重建或遮蔽播放器。
///
/// 注意：
/// - 不启动真实播放器、Runtime、网络或平台媒体后端。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/media/presentation/media_entry_cover.dart';

void main() {
  testWidgets('shows the local novel cover immediately while audio prepares', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: MediaEntryCoverSurface(kind: MediaEntryKind.audio, title: '测试听书', coverBytes: _onePixelPng, onExit: () {}),
      ),
    );

    expect(find.byKey(const Key('media-entry-cover-image')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('正在准备音频'), findsOneWidget);
    expect(tester.getSemantics(find.byKey(const Key('media-entry-status'))).label, contains('正在准备音频'));
    final region = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(find.byType(AnnotatedRegion<SystemUiOverlayStyle>));
    expect(region.value.statusBarColor, Colors.transparent);
    expect(region.value.systemNavigationBarColor, Colors.transparent);
    expect(region.value.statusBarIconBrightness, Brightness.light);
    expect(region.value.systemNavigationBarIconBrightness, Brightness.light);
  });

  testWidgets('keeps the player mounted and removes the cover after presentation', (tester) async {
    var presented = false;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return MediaEntryCoverTransition(
              kind: MediaEntryKind.video,
              title: '测试视频',
              coverBytes: _onePixelPng,
              presented: presented,
              onExit: () {},
              child: const ColoredBox(key: Key('mounted-player'), color: Colors.black),
            );
          },
        ),
      ),
    );

    expect(find.byKey(const Key('mounted-player')), findsOneWidget);
    expect(find.byKey(const Key('media-entry-cover-image')), findsOneWidget);

    update(() => presented = true);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('mounted-player')), findsOneWidget);
    expect(find.byKey(const Key('media-entry-cover-transition')), findsNothing);
  });

  testWidgets('allows returning from the preparation cover transition', (tester) async {
    var exits = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: MediaEntryCoverTransition(
          kind: MediaEntryKind.video,
          title: '测试视频',
          coverBytes: _onePixelPng,
          presented: false,
          onExit: () => exits++,
          child: const ColoredBox(key: Key('mounted-player'), color: Colors.black),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('media-entry-back')));

    expect(exits, 1);
  });

  testWidgets('shows video artwork in the player viewport without stretching it', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: MediaEntryCoverSurface(kind: MediaEntryKind.video, title: '横屏视频', coverBytes: _onePixelPng, onExit: () {}),
      ),
    );

    final image = tester.widget<Image>(find.byKey(const Key('media-entry-cover-image')));
    expect(image.fit, BoxFit.contain);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('turns setup failure into a visible retry action', (tester) async {
    var retries = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: MediaEntryCoverSurface(
          kind: MediaEntryKind.video,
          title: '测试视频',
          coverBytes: null,
          failureMessage: '初始化失败',
          failureLocation: '后台播放服务初始化',
          failureCode: 'audio_service_setup_failed',
          failureDetail: 'AudioService init rejected',
          onRetry: () => retries++,
          onExit: () {},
        ),
      ),
    );

    expect(find.text('视频暂时无法打开'), findsOneWidget);
    expect(find.text('初始化失败'), findsOneWidget);
    expect(find.text('发生位置：后台播放服务初始化  ·  诊断编号：audio_service_setup_failed'), findsOneWidget);
    expect(find.text('技术原因：AudioService init rejected'), findsOneWidget);
    await tester.tap(find.byKey(const Key('media-entry-retry')));
    expect(retries, 1);
  });
}

const List<int> _onePixelPng = <int>[
  137,
  80,
  78,
  71,
  13,
  10,
  26,
  10,
  0,
  0,
  0,
  13,
  73,
  72,
  68,
  82,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  1,
  8,
  6,
  0,
  0,
  0,
  31,
  21,
  196,
  137,
  0,
  0,
  0,
  13,
  73,
  68,
  65,
  84,
  120,
  156,
  99,
  248,
  207,
  192,
  240,
  31,
  0,
  5,
  0,
  1,
  255,
  137,
  153,
  61,
  29,
  0,
  0,
  0,
  0,
  73,
  69,
  78,
  68,
  174,
  66,
  96,
  130,
];
