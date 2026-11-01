/// TV remote regressions, sharing the injected backend fixtures of the session tests.
part of 'video_player_view_test.dart';

void _registerTvTests() {
  testWidgets(
    'TV seeking chrome auto-hides and returns directional seeking to the stage',
    (tester) async {
      final backend = _FakeVideoBackend();
      final controller = VideoPlayerController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: VideoPlayerView(
            tvMode: true,
            contentId: 'show',
            dataSource: const _ImmediateDataSource(),
            stateStore: _RecordingStore(),
            controller: controller,
            backendFactory: () => backend,
            controlsAutoHideDelay: const Duration(seconds: 1),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(controller.snapshot.position, const Duration(seconds: 10));
      expect(controller.snapshot.controlsVisible, isTrue);
      await tester.pump(const Duration(milliseconds: 1100));
      await tester.pumpAndSettle();
      expect(controller.snapshot.controlsVisible, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(controller.snapshot.position, const Duration(seconds: 20));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'TV focused controls hide after inactivity while remote movement restarts the delay',
    (tester) async {
      final controller = VideoPlayerController();
      final backend = _FakeVideoBackend();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: VideoPlayerView(
            tvMode: true,
            contentId: 'show',
            dataSource: const _ImmediateDataSource(),
            stateStore: _RecordingStore(),
            controller: controller,
            backendFactory: () => backend,
            controlsAutoHideDelay: const Duration(seconds: 3),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('tv-video-play')))
            .focusNode!
            .hasFocus,
        isTrue,
      );
      await tester.pump(const Duration(milliseconds: 1000));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(backend.seekCalls, isEmpty);
      await tester.pump(const Duration(milliseconds: 2000));
      expect(controller.snapshot.controlsVisible, isTrue);
      await tester.pump(const Duration(milliseconds: 1200));
      await tester.pumpAndSettle();
      expect(controller.snapshot.controlsVisible, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(controller.snapshot.position, const Duration(seconds: 10));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'TV paused playback and open menus retain controls, then resume hiding after dismissal',
    (tester) async {
      final controller = VideoPlayerController();
      final backend = _FakeVideoBackend();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: VideoPlayerView(
            tvMode: true,
            contentId: 'show',
            dataSource: const _ImmediateDataSource(),
            stateStore: _RecordingStore(),
            controller: controller,
            backendFactory: () => backend,
            controlsAutoHideDelay: const Duration(seconds: 1),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await controller.pause();
      await tester.pump(const Duration(seconds: 2));
      expect(controller.snapshot.controlsVisible, isTrue);
      await controller.play();
      await tester.pumpAndSettle();
      for (final key in ['tv-video-rate', 'tv-video-episodes']) {
        await tester.tap(find.byKey(Key(key)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(seconds: 2));
        expect(controller.snapshot.controlsVisible, isTrue);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(controller.snapshot.controlsVisible, isTrue);
        await tester.pump(const Duration(milliseconds: 1100));
        await tester.pumpAndSettle();
        expect(controller.snapshot.controlsVisible, isFalse);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'TV playback starts unobstructed and holding OK does not repeatedly toggle playback',
    (tester) async {
      final backend = _FakeVideoBackend();
      final controller = VideoPlayerController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: VideoPlayerView(
            tvMode: true,
            contentId: 'show',
            dataSource: const _ImmediateDataSource(),
            stateStore: _RecordingStore(),
            controller: controller,
            backendFactory: () => backend,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.snapshot.controlsVisible, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.pump();
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
        await tester.pump();
      }
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(backend.state.value.playing, isFalse);
      expect(backend.pauseCount, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'TV controls fit enlarged text and directions reach the bottom action and rate menu',
    (tester) async {
      tester.view.physicalSize = const Size(640, 360);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = _FakeVideoBackend();
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.6)),
            child: child!,
          ),
          home: VideoPlayerView(
            tvMode: true,
            contentId: 'show',
            dataSource: const _ImmediateDataSource(),
            stateStore: _RecordingStore(),
            backendFactory: () => backend,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // The panel is scrollable, but must remain navigable without touch/Tab.
      for (var i = 0; i < 8; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
      }
      // At large text the bottom row has fit and exit side by side.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      final exitButton = find.byKey(const Key('tv-video-exit'));
      expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<FilledButton>()
            ?.key,
        const Key('tv-video-exit'),
      );
      expect(tester.getRect(exitButton).bottom, lessThanOrEqualTo(360));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      for (var i = 0; i < 6; i++) {
        if (FocusManager.instance.primaryFocus?.context
                ?.findAncestorWidgetOfExactType<FilledButton>()
                ?.key ==
            const Key('tv-video-rate')) {
          break;
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
      }
      expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<FilledButton>()
            ?.key,
        const Key('tv-video-rate'),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.text('播放速度'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'TV remote separates stage seeking from control traversal and backs out in two steps',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = _FakeVideoBackend();
      final observer = _RecordingObserver();
      final controller = VideoPlayerController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: VideoPlayerView(
            tvMode: true,
            contentId: 'show',
            dataSource: const _ImmediateDataSource(),
            stateStore: _RecordingStore(),
            observer: observer,
            controller: controller,
            backendFactory: () => backend,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(backend.state.value.playing, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(backend.state.value.playing, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(backend.seekCalls.last, const Duration(seconds: 10));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('tv-video-play')))
            .focusNode!
            .hasFocus,
        isTrue,
      );
      final seeks = backend.seekCalls.length;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(backend.seekCalls.length, seeks);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(backend.seekCalls.length, seeks + 1);
      await tester.tap(find.byKey(const Key('tv-video-episodes')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('video-player-episode-sheet')),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('video-player-episode-sheet')), findsNothing);
      expect(observer.exitCount, 0);
      await tester.tap(find.byKey(const Key('tv-video-rate')));
      await tester.pumpAndSettle();
      expect(find.text('播放速度'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.text('播放速度'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(controller.snapshot.controlsVisible, isFalse);
      expect(observer.exitCount, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(observer.exitCount, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
