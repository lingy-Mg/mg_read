/// Portrait presentation, settings, queue and golden tests for the audio UI.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read_audio_player/mg_read_audio_player.dart';

import 'support/audio_visual_fonts.dart';

part 'support/audio_presentation_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAudioVisualFonts);

  testWidgets('navigation actions have full size touch targets', (
    tester,
  ) async {
    _setPortraitView(tester);
    await tester.pumpWidget(_host(backend: _PresentationBackend()));
    await tester.pump();
    await tester.pump();
    for (final name in ['audio-back', 'audio-more']) {
      final size = tester.getSize(find.byKey(Key(name)));
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(44));
    }
    expect(find.text('已暂停'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('audio-track-title'))).data,
      '第一章 从这里开始',
    );
  });

  testWidgets('shows a dedicated empty queue recovery state', (tester) async {
    await tester.pumpWidget(
      _host(
        backend: _PresentationBackend(),
        dataSource: const _EmptyDataSource(),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('暂无可播放内容'), findsOneWidget);
    expect(find.text('当前内容暂无可播放章节。'), findsOneWidget);
    expect(find.byKey(const Key('audio-retry')), findsOneWidget);
  });

  testWidgets('settings sheet controls rate volume mute and sleep timer', (
    tester,
  ) async {
    final backend = _PresentationBackend();
    final controller = AudioPlayerController();

    await tester.pumpWidget(_host(backend: backend, controller: controller));
    await tester.pump();
    await tester.pump();

    await tester.ensureVisible(find.byKey(const Key('audio-settings')));
    await tester.tap(find.byKey(const Key('audio-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('audio-rate')), findsOneWidget);
    expect(find.byKey(const Key('audio-volume')), findsOneWidget);
    expect(find.byKey(const Key('audio-timer')), findsOneWidget);
    expect(find.byKey(const Key('audio-settings-summary')), findsOneWidget);
    expect(find.text('音乐播放设置'), findsOneWidget);
    expect(find.text('0.5'), findsOneWidget);
    expect(find.text('0.75'), findsOneWidget);
    expect(find.textContaining(r'$'), findsNothing);

    await tester.tap(find.byKey(const Key('audio-rate-175')));
    await tester.pump();
    expect(backend.rates.last, 1.75);

    await tester.drag(
      find.byKey(const Key('audio-volume-slider')),
      const Offset(-90, 0),
    );
    await tester.pump();
    expect(backend.volumes.last, lessThan(1));
    expect(backend.volumes.last, greaterThan(0));

    await tester.tap(find.byKey(const Key('audio-volume-mute')));
    await tester.pump();
    expect(backend.volumes.last, 0);

    final timer45 = find.byKey(const Key('audio-timer-45'));
    await tester.ensureVisible(timer45);
    await tester.pumpAndSettle();
    await tester.tap(timer45);
    await tester.pump();
    expect(controller.snapshot.sleepTimerDuration, const Duration(minutes: 45));
    await tester.tap(find.byKey(const Key('audio-timer-off')));
    await tester.pump();
    expect(controller.snapshot.sleepTimerDuration, isNull);

    await tester.tap(find.byKey(const Key('audio-settings-done')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('audio-settings-sheet')), findsNothing);

    controller.dispose();
  });

  testWidgets('compact portrait keeps every settings group and done action', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _host(backend: _PresentationBackend(), size: const Size(400, 700)),
    );
    await tester.pump();
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('audio-settings')));
    await tester.tap(find.byKey(const Key('audio-settings')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('audio-rate')), findsOneWidget);
    expect(find.byKey(const Key('audio-volume')), findsOneWidget);
    expect(find.byKey(const Key('audio-timer')), findsOneWidget);
    expect(find.byKey(const Key('audio-settings-done')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('queue sheet highlights current and protects locked chapters', (
    tester,
  ) async {
    final backend = _PresentationBackend();

    await tester.pumpWidget(
      _host(backend: backend, dataSource: const _QueueDataSource()),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('audio-queue')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('audio-queue-list')), findsOneWidget);
    final queueClip = find.descendant(
      of: find.byKey(const Key('audio-queue-glass')),
      matching: find.byType(ClipRRect),
    );
    expect(
      tester.widget<ClipRRect>(queueClip.first).borderRadius,
      const BorderRadius.vertical(top: Radius.circular(24)),
    );
    expect(find.text('已暂停'), findsAtLeastNWidgets(2));
    expect(find.text('需解锁后播放'), findsOneWidget);

    await tester.tap(find.byKey(const Key('audio-queue-track-locked')));
    await tester.pump();
    expect(find.byKey(const Key('audio-queue-list')), findsOneWidget);
    expect(backend.snapshot.currentIndex, 0);

    await tester.tap(find.byKey(const Key('audio-queue-track-track-2')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('audio-queue-list')), findsNothing);
    expect(backend.snapshot.currentIndex, 1);
  });

  testWidgets('queue indicator moves while playing and stops when paused', (
    tester,
  ) async {
    final backend = _PresentationBackend();

    await tester.pumpWidget(
      _host(
        backend: backend,
        dataSource: const _QueueDataSource(),
        disableAnimations: false,
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('audio-play-pause')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('audio-queue')));
    await tester.pump(const Duration(milliseconds: 400));

    final bar = find.byKey(const Key('audio-queue-playing-bar-0'));
    expect(
      find.byKey(const Key('audio-queue-playing-indicator')),
      findsOneWidget,
    );
    final barHeights = List<double>.generate(
      5,
      (index) => tester
          .getSize(find.byKey(Key('audio-queue-playing-bar-$index')))
          .height,
    );
    expect(barHeights.toSet().length, greaterThanOrEqualTo(4));
    final movingHeight = tester.getSize(bar).height;
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.getSize(bar).height, isNot(closeTo(movingHeight, 0.01)));

    await backend.pause();
    await tester.pump();
    final pausedHeight = tester.getSize(bar).height;
    await tester.pump(const Duration(milliseconds: 160));
    expect(tester.getSize(bar).height, closeTo(pausedHeight, 0.01));
  });

  testWidgets('current queue title scrolls only when it overflows', (
    tester,
  ) async {
    _setPortraitView(tester);
    await tester.pumpWidget(
      _host(
        backend: _PresentationBackend(),
        dataSource: const _LongLabelDataSource(),
        disableAnimations: false,
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('audio-queue')));
    await tester.pump(const Duration(milliseconds: 400));

    final marquee = find.byKey(const Key('audio-queue-current-title-marquee'));
    expect(marquee, findsOneWidget);
    final initialX = tester.getTopLeft(marquee).dx;
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.getTopLeft(marquee).dx, lessThan(initialX));
  });

  testWidgets('current queue title remains still when it fits', (tester) async {
    _setPortraitView(tester);
    await tester.pumpWidget(
      _host(
        backend: _PresentationBackend(),
        dataSource: const _QueueDataSource(),
        disableAnimations: false,
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('audio-queue')));
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.byKey(const Key('audio-queue-current-title-static')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('audio-queue-current-title-marquee')),
      findsNothing,
    );
  });

  testWidgets('title creator and episode metadata open live audio details', (
    tester,
  ) async {
    final backend = _PresentationBackend();
    await tester.pumpWidget(
      _host(
        backend: backend,
        artworkBuilder: (_, _) => const ColoredBox(
          key: Key('details-artwork-content'),
          color: Color(0xFF8A4B36),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    for (final key in <Key>[
      const Key('audio-track-title'),
      const Key('audio-track-creator'),
      const Key('audio-track-position'),
    ]) {
      await tester.tap(find.byKey(key));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('audio-details-sheet')), findsOneWidget);
      await tester.tap(find.byKey(const Key('audio-details-close')));
      await tester.pumpAndSettle();
    }

    await tester.tap(find.byKey(const Key('audio-track-title')));
    await tester.pumpAndSettle();
    final details = find.byKey(const Key('audio-details-sheet'));
    expect(find.text('音频详情'), findsOneWidget);
    expect(find.byKey(const Key('audio-details-artwork')), findsOneWidget);
    expect(find.byKey(const Key('details-artwork-content')), findsNWidgets(3));
    expect(
      tester.widget<Text>(find.byKey(const Key('audio-details-title'))).data,
      '风声书场',
    );
    expect(
      find.descendant(of: details, matching: find.text('作者 / 播讲：讲述者')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: details, matching: find.text('第 1 集')),
      findsNWidgets(2),
    );
    expect(
      find.descendant(of: details, matching: find.text('2 集')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: details,
        matching: find.byKey(const Key('audio-details-current-track')),
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('audio-details-resource'))).data,
      'https://example.test/audio/1.mp3',
    );
    expect(
      tester
          .widget<Text>(find.byKey(const Key('audio-details-resource')))
          .maxLines,
      1,
    );
    expect(
      find.byKey(const Key('audio-details-resource-copy')),
      findsOneWidget,
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('audio-details-source'))).data,
      'https://example.test/books/book-1/chapters/chapter-1',
    );
    expect(
      tester
          .widget<Text>(find.byKey(const Key('audio-details-source')))
          .maxLines,
      1,
    );
    expect(find.byKey(const Key('audio-details-source-copy')), findsOneWidget);
    expect(find.text('来源地址'), findsOneWidget);
    expect(find.text('播放地址'), findsOneWidget);
    expect(find.byKey(const Key('audio-details-progress')), findsNothing);
    expect(find.text('播放信息'), findsNothing);
    expect(find.text('播放速度'), findsNothing);
    expect(find.text('音量'), findsNothing);

    expect(
      find.byKey(const Key('audio-details-comment-composer')),
      findsNothing,
    );
    expect(find.text('即将开放'), findsNothing);
  });

  testWidgets(
    'runtime resource URL exposes copy and decoded parameter actions',
    (tester) async {
      await tester.pumpWidget(
        _host(
          backend: _PresentationBackend(),
          resourceUrlDecoder: (resource) async =>
              const AudioResourceDecodeResult(
                pluginId: 'org.example.audio',
                requestJson: '{\n  "kind": "audio"\n}',
              ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const Key('audio-track-title')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('audio-details-resource-copy')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('audio-details-source-copy')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('audio-details-resource-decoded')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('audio-details-resource-decoded-copy')),
        findsOneWidget,
      );
    },
  );

  testWidgets('large catalog keeps its count in secondary metadata', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        backend: _PresentationBackend(),
        dataSource: const _LargeQueueDataSource(),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('999+'), findsNothing);
    expect(find.text('第 1 集  ·  共 2008 集'), findsOneWidget);
  });

  testWidgets('host artwork becomes the blurred immersive backdrop', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        backend: _PresentationBackend(),
        artworkBuilder: (_, _) => const ColoredBox(
          key: Key('presentation-artwork'),
          color: Color(0xFF8A4B36),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final backdrop = find.byKey(const Key('audio-artwork-backdrop'));
    expect(backdrop, findsOneWidget);
    expect(
      find.descendant(of: backdrop, matching: find.byType(ImageFiltered)),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('audio-artwork-backdrop-cover')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('presentation-artwork')), findsNWidgets(2));
  });

  testWidgets('position ticks rebuild progress without repainting artwork', (
    tester,
  ) async {
    final backend = _PresentationBackend();
    var artworkBuilds = 0;
    await tester.pumpWidget(
      _host(
        backend: backend,
        artworkBuilder: (_, _) {
          artworkBuilds += 1;
          return const ColoredBox(color: Color(0xFF8A4B36));
        },
      ),
    );
    await tester.pump();
    await tester.pump();

    final buildsBeforeTick = artworkBuilds;
    await backend.seek(const Duration(seconds: 10));
    await tester.pump();

    expect(find.text('0:10'), findsOneWidget);
    expect(artworkBuilds, buildsBeforeTick);
  });

  testWidgets('player and sheets avoid stacked backdrop filters', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        backend: _PresentationBackend(),
        dataSource: const _QueueDataSource(),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byKey(const Key('audio-cover-frame')), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('audio-settings')));
    await tester.tap(find.byKey(const Key('audio-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('audio-settings-sheet')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('audio-settings-sheet')),
        matching: find.byType(BackdropFilter),
      ),
      findsNothing,
    );
    await tester.tap(find.byKey(const Key('audio-settings-close')));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('audio-queue')));
    await tester.tap(find.byKey(const Key('audio-queue')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('audio-queue-glass')), findsOneWidget);
    await tester.tap(find.byKey(const Key('audio-queue-close')));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('audio-track-title')));
    await tester.tap(find.byKey(const Key('audio-track-title')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('audio-details-glass')), findsOneWidget);
  });

  testWidgets('sheets inherit player colors from a light host', (tester) async {
    _setPortraitView(tester);
    await tester.pumpWidget(_host(backend: _PresentationBackend()));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('audio-more')));
    await tester.pumpAndSettle();
    final closeContext = tester.element(
      find.byKey(const Key('audio-details-close')),
    );
    expect(Theme.of(closeContext).brightness, Brightness.dark);
    final style = IconButtonTheme.of(closeContext).style!;
    expect(
      style.foregroundColor!.resolve(<WidgetState>{}),
      const Color(0xFFF6F7F9),
    );
  });

  testWidgets('short portrait keeps the complete control area on first view', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _host(
        backend: _PresentationBackend(),
        dataSource: const _LargeQueueDataSource(),
        size: const Size(400, 700),
        textScale: 1,
      ),
    );
    await tester.pump();
    await tester.pump();

    final settings = find.byKey(const Key('audio-settings'));
    expect(settings, findsOneWidget);
    expect(tester.getBottomRight(settings).dy, lessThanOrEqualTo(700));
    expect(find.byType(Scrollbar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact portrait and large text remain overflow free', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _host(
        backend: _PresentationBackend(),
        dataSource: const _LongLabelDataSource(),
        size: const Size(360, 640),
        textScale: 1.35,
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('audio-play-pause')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final size in <Size>[
    Size(390, 844),
    Size(320, 568),
    Size(844, 390),
    Size(1024, 768),
  ]) {
    testWidgets('usable controls at $size with safe areas', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        _host(
          backend: _PresentationBackend(),
          size: size,
          textScale: 1,
          safePadding: const EdgeInsets.only(top: 24, bottom: 24),
        ),
      );
      await tester.pump();
      await tester.pump();
      if (size.width == 844 || size.width == 320) {
        await expectLater(
          find.byType(AudioPlayerView),
          matchesGoldenFile(
            'goldens/audio_player_${size.width == 844 ? 'landscape' : 'compact'}_${size.width.toInt()}x${size.height.toInt()}.png',
          ),
        );
      }
      final play = find.byKey(const Key('audio-play-pause'));
      await tester.ensureVisible(play);
      await tester.tap(play);
      await tester.pump();
      expect(find.byTooltip('暂停'), findsOneWidget);
      final queue = find.byKey(const Key('audio-queue'));
      await tester.ensureVisible(queue);
      await tester.tap(queue);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('audio-queue-list')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('timer shortcut reveals timer choices on a compact phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = AudioPlayerController();
    await tester.pumpWidget(
      _host(backend: _PresentationBackend(), controller: controller),
    );
    await tester.pump();
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('audio-quick-timer')));
    await tester.tap(find.byKey(const Key('audio-quick-timer')));
    await tester.pumpAndSettle();
    final timer = find.byKey(const Key('audio-timer-30'));
    expect(timer.hitTestable(), findsOneWidget);
    await tester.tap(timer);
    await tester.pump();
    expect(controller.snapshot.sleepTimerDuration, const Duration(minutes: 30));
    await tester.tap(find.byKey(const Key('audio-settings-done')));
    await tester.pumpAndSettle();
    expect(find.text('30 分钟'), findsOneWidget);
    controller.dispose();
  });

  testWidgets('ready player matches the portrait visual baseline', (
    tester,
  ) async {
    _setPortraitView(tester);
    await tester.pumpWidget(
      _host(
        backend: _PresentationBackend(),
        textScale: 1,
        artworkBuilder: _goldenArtworkBuilder,
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.pumpAndSettle();
    await expectLater(
      find.byType(AudioPlayerView),
      matchesGoldenFile('goldens/audio_player_ready_390x844.png'),
    );
  });

  testWidgets('settings and queue match portrait visual baselines', (
    tester,
  ) async {
    _setPortraitView(tester);
    await tester.pumpWidget(
      _host(
        backend: _PresentationBackend(),
        dataSource: const _QueueDataSource(),
        textScale: 1,
        artworkBuilder: _goldenArtworkBuilder,
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('audio-settings')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(Overlay),
      matchesGoldenFile('goldens/audio_player_settings_390x844.png'),
    );

    await tester.tap(find.byKey(const Key('audio-settings-close')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('audio-queue')));
    await tester.tap(find.byKey(const Key('audio-queue')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(Overlay),
      matchesGoldenFile('goldens/audio_player_queue_390x844.png'),
    );
  });

  testWidgets('audio details match the portrait visual baseline', (
    tester,
  ) async {
    _setPortraitView(tester);
    await tester.pumpWidget(
      _host(
        backend: _PresentationBackend(),
        textScale: 1,
        artworkBuilder: (_, _) => const ColoredBox(color: Color(0xFF8A4B36)),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('audio-track-title')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(Overlay),
      matchesGoldenFile('goldens/audio_player_details_390x844.png'),
    );
  });
}
