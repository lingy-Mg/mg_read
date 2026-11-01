/// On-device TV layout/orientation and remote navigation acceptance.
/// Runs in a suffixed test app with deterministic metadata and an injected
/// engine: validates real Android window sizing, not network/native decoding.
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/app/app_tv_theme.dart';
import 'package:mg_read/features/media/application/source_video_fullscreen_controller.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:mg_read_video_player/mg_read_video_player.dart';
import '../test/support/tv_media_test_fixture.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('TV detail opens a full-width landscape player and remote controls', (tester) async {
    expect(
      const String.fromEnvironment('MGREAD_APPLICATION_ID_SUFFIX'),
      'tvqa',
      reason: 'Use --dart-define=MGREAD_APPLICATION_ID_SUFFIX=tvqa to preserve the installed app.',
    );
    final navigator = GlobalKey<NavigatorState>();
    final fullscreen = SourceVideoFullscreenController(tvMode: true);
    final controller = VideoPlayerController();
    final store = TvFixtureVideoStore();
    addTearDown(controller.dispose);
    addTearDown(fullscreen.restoreAndClose);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        navigatorKey: navigator,
        theme: appTvTheme(AppTheme.dark()),
        builder: (_, child) => TvModeScope(
          enabled: true,
          onChanged: (_) {},
          child: TvRemoteShortcuts(child: child!),
        ),
        home: TvDetailFixtureEntry(
          onSave: (_, _) async {},
          onPlay: ({required detail, required firstCatalogPage, required chapter}) async {
            await fullscreen.activate();
            unawaited(
              navigator.currentState!.push<void>(
                MaterialPageRoute(
                  builder: (_) => VideoPlayerView(
                    tvMode: true,
                    contentId: 'show',
                    dataSource: TvFixtureVideoSource(),
                    stateStore: store,
                    controller: controller,
                    backendFactory: TvFixtureVideoBackend.new,
                    observer: _TvExitObserver(() => navigator.currentState!.pop()),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 15));
    expect(find.byKey(const Key('tv-video-detail-summary')), findsOneWidget);
    expect(find.text('字数'), findsNothing);
    await binding.convertFlutterSurfaceToImage();
    await tester.pump();
    await binding.takeScreenshot('tv_video_detail');
    await _press(tester, LogicalKeyboardKey.select);
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 15));
    expect(find.byType(VideoPlayerView), findsOneWidget);
    final size = MediaQuery.sizeOf(tester.element(find.byType(VideoPlayerView)));
    expect(size.width, greaterThan(size.height));
    final stage = tester.getSize(find.byKey(const Key('video-player-surface')));
    expect(stage.width, closeTo(size.width, 1));
    expect(stage.height, closeTo(size.height, 1));
    expect(controller.snapshot.controlsVisible, isFalse);
    await _press(tester, LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 200));
    expect(controller.snapshot.position, const Duration(seconds: 10));
    await _press(tester, LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tv-video-play')).hitTestable(), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const Key('tv-video-exit'))).dy,
      closeTo(tester.getTopLeft(find.byKey(const Key('tv-video-play'))).dy, 1),
    );
    expect(tester.getSize(find.byKey(const Key('tv-video-controls-scroll'))).height, lessThan(size.height * .45));
    await _press(tester, LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(controller.snapshot.playing, isFalse);
    await binding.takeScreenshot('tv_video_player_controls');
    for (var i = 0; i < 3; i++) {
      await _press(tester, LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
    }
    await _press(tester, LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('video-player-episode-sheet')), findsOneWidget);
    await binding.takeScreenshot('tv_video_player_episodes');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await _press(tester, LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(controller.snapshot.controlsVisible, isFalse);
    await _press(tester, LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(VideoPlayerView), findsNothing);
    expect(store.saved, isNotNull);
    expect(find.byKey(const Key('tv-video-detail-summary')), findsOneWidget);
    await fullscreen.restoreAndClose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }, timeout: const Timeout(Duration(minutes: 2)));
}

// Profile builds omit key debug names, so the simulator needs explicit HID keys.
Future<bool> _press(WidgetTester tester, LogicalKeyboardKey key) => tester.sendKeyEvent(
  key,
  physicalKey: {
    LogicalKeyboardKey.select: PhysicalKeyboardKey.enter,
    LogicalKeyboardKey.arrowRight: PhysicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.arrowDown: PhysicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.escape: PhysicalKeyboardKey.escape,
  }[key],
);

class _TvExitObserver extends VideoPlayerObserver {
  _TvExitObserver(this.onExit);
  final VoidCallback onExit;
  @override
  void onExitRequested(VideoPlaybackProgress? progress) => onExit();
}
