/// Input-specific transport regressions using the layout test's fake backend.
/// Covers mouse recovery after auto-hide and actual visible playback commands.
part of 'video_player_layout_test.dart';

void _registerTransportTests() {
  testWidgets(
    'desktop transport stays visible while the pointer rests on a control',
    (tester) async {
      final backend = _Backend();
      final controller = VideoPlayerController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _playerApp(
          backend: backend,
          controller: controller,
          controlsDelay: const Duration(seconds: 1),
        ),
      );
      await tester.pumpAndSettle();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(300, 200));
      await mouse.moveTo(
        tester.getCenter(find.byKey(const Key('video-player-play-pause'))),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
      expect(controller.snapshot.controlsVisible, isTrue);
      await controller.seek(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
      expect(controller.snapshot.controlsVisible, isTrue);
      await mouse.moveTo(const Offset(300, 200));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(controller.snapshot.controlsVisible, isFalse);
      await mouse.removePointer();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'desktop transport controls playback volume seek and episodes',
    (tester) async {
      final backend = _Backend();
      await tester.pumpWidget(_playerApp(backend: backend));
      await tester.pumpAndSettle();
      final bottom = find.byKey(const Key('video-player-bottom-band'));
      for (final key in [
        'play-pause',
        'mute',
        'volume',
        'next',
        'settings',
        'episodes',
        'fullscreen',
      ]) {
        expect(
          find
              .descendant(
                of: bottom,
                matching: find.byKey(Key('video-player-$key')),
              )
              .hitTestable(),
          findsOneWidget,
        );
      }
      expect(find.byKey(const Key('video-player-rewind')), findsNothing);
      await tester.tap(find.byKey(const Key('video-player-play-pause')));
      await tester.pump();
      expect(backend.state.value.playing, isFalse);
      await tester.tap(find.byKey(const Key('video-player-play-pause')));
      await tester.pump();
      expect(backend.state.value.playing, isTrue);
      await tester.tap(find.byKey(const Key('video-player-mute')));
      await tester.pump();
      expect(backend.state.value.volume, 0);
      await tester.tap(find.byKey(const Key('video-player-mute')));
      await tester.pump();
      expect(backend.state.value.volume, 100);
      await tester.drag(
        find.byKey(const Key('video-player-volume')),
        const Offset(-20, 0),
      );
      await tester.pump();
      expect(backend.state.value.volume, inExclusiveRange(0, 100));
      await tester.drag(
        find.byKey(const Key('video-player-slider')),
        const Offset(120, 0),
      );
      await tester.pumpAndSettle();
      expect(backend.seeks, hasLength(1));
      expect(backend.seeks.single, greaterThan(Duration.zero));
      await tester.tap(find.byKey(const Key('video-player-next')));
      await tester.pumpAndSettle();
      expect(find.text('播放源 · 第 2 集'), findsOneWidget);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    }),
  );

  testWidgets(
    'desktop hover restores controls and open settings keep them available',
    (tester) async {
      final backend = _Backend();
      final controller = VideoPlayerController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _playerApp(
          backend: backend,
          controller: controller,
          controlsDelay: const Duration(seconds: 1),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 200));
      expect(controller.snapshot.controlsVisible, isFalse);
      expect(
        find.byKey(const Key('video-player-play-pause')).hitTestable(),
        findsNothing,
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(300, 200));
      await mouse.moveTo(const Offset(320, 210));
      await tester.pumpAndSettle();
      expect(controller.snapshot.controlsVisible, isTrue);
      await tester.tap(find.byKey(const Key('video-player-settings')));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      await tester.pump(const Duration(seconds: 4));
      expect(controller.snapshot.controlsVisible, isTrue);
      await tester.tap(find.byKey(const Key('video-player-rate-1-5')));
      await tester.pumpAndSettle();
      expect(backend.state.value.rate, 1.5);
      await tester.tap(find.byKey(const Key('video-player-settings-close')));
      await tester.pumpAndSettle();
      await mouse.removePointer();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(controller.snapshot.controlsVisible, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.pumpAndSettle();
      expect(controller.snapshot.playing, isFalse);
      expect(controller.snapshot.controlsVisible, isTrue);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  for (final size in [const Size(320, 568), const Size(844, 390)]) {
    testWidgets(
      'touch transport remains usable at $size with enlarged text',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final backend = _Backend();
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(1.6),
                padding: const EdgeInsets.only(bottom: 24),
              ),
              child: child!,
            ),
            home: VideoPlayerView(
              contentId: 'show',
              dataSource: const _Source(),
              stateStore: const _Store(),
              backendFactory: () => backend,
              controlsAutoHideDelay: const Duration(hours: 1),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (final key in [
          'play-pause',
          'rewind',
          'forward',
          'slider',
          'episodes',
          'settings',
          'fullscreen',
        ]) {
          expect(
            find.byKey(Key('video-player-$key')).hitTestable(),
            findsOneWidget,
          );
        }
        expect(find.byKey(const Key('video-player-volume')), findsNothing);
        await tester.tap(find.byKey(const Key('video-player-forward')));
        await tester.pump();
        expect(backend.state.value.position, const Duration(seconds: 10));
        await tester.tap(find.byKey(const Key('video-player-play-pause')));
        await tester.pump();
        expect(backend.state.value.playing, isFalse);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.iOS,
      }),
    );
  }

  testWidgets(
    'compact desktop uses pointer behavior without overflowing transport',
    (tester) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = _Backend();
      final controller = VideoPlayerController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _playerApp(backend: backend, controller: controller),
      );
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(160, 180));
      await tester.pump(const Duration(milliseconds: 400));
      expect(backend.state.value.playing, isFalse);
      for (final key in ['play-pause', 'episodes', 'settings', 'fullscreen']) {
        expect(
          find.byKey(Key('video-player-$key')).hitTestable(),
          findsOneWidget,
        );
      }
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
