import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/tv_companion/domain/companion_models.dart';
import 'package:mg_read/features/tv_companion/presentation/companion_remote.dart';

import '../application/companion_controller_testkit.dart';

void main() {
  late CompanionPairFixture fixture;

  tearDown(() async => fixture.close());

  testWidgets('shows TV idle and keeps playback controls disabled without fresh state', (tester) async {
    tester.view.physicalSize = const Size(480, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.runAsync(() async {
      fixture = await CompanionPairFixture.create();
    });
    fixture.phone.connectionStatus = CompanionConnectionStatus.connected;
    fixture.phone.remoteState = const CompanionPlaybackSnapshot(
      sequence: 1,
      hostEpoch: 'widget-host',
      serverMs: 0,
      controlGeneration: 0,
      playbackGeneration: 0,
      status: 'idle',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
          child: CompanionRemote(service: fixture.phone),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.scrollUntilVisible(find.text('TV 待机'), 120);
    expect(find.text('TV 待机'), findsOneWidget);
    await tester.scrollUntilVisible(find.byTooltip('播放'), 120);
    final play = tester.widget<IconButton>(find.ancestor(of: find.byTooltip('播放'), matching: find.byType(IconButton)));
    expect(play.onPressed, isNull);
    expect(fixture.phone.connectionStatus, CompanionConnectionStatus.connected);
    expect(tester.takeException(), isNull);
  });
}
