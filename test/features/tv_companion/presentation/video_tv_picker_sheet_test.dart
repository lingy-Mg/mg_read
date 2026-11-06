/// Layout and interaction regression tests for the player's TV picker.
/// Discovery and playback are owned by the caller, so these tests use no IO.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/tv_companion/domain/companion_models.dart';
import 'package:mg_read/features/tv_companion/presentation/video_tv_picker_sheet.dart';

void main() {
  testWidgets('empty picker keeps manual, retry and close actions accessible', (tester) async {
    var manual = 0;
    var retry = 0;
    var close = 0;
    await tester.pumpWidget(_app(onManual: () => manual++, onRetry: () => retry++, onClose: () => close++));
    expect(find.text('还没有发现电视'), findsOneWidget);
    expect(find.text('电视开始播放后，手机会自动暂停'), findsOneWidget);
    await tester.tap(find.byKey(const Key('companion-cast-manual')));
    await tester.tap(find.byKey(const Key('companion-cast-retry')));
    await tester.tap(find.byKey(const Key('companion-cast-close')));
    expect((manual, retry, close), (1, 1, 1));
  });

  testWidgets('search state prevents repeated retry while allowing manual input', (tester) async {
    var manual = 0;
    await tester.pumpWidget(_app(loading: true, onManual: () => manual++));
    expect(find.text('正在寻找附近的电视'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('companion-cast-retry'))).onPressed, isNull);
    await tester.tap(find.byKey(const Key('companion-cast-manual')));
    expect(manual, 1);
  });

  testWidgets('device card selects the exact endpoint and errors remain retryable', (tester) async {
    final endpoint = CompanionEndpoint(
      deviceId: 'living-room',
      label: '客厅电视',
      address: '192.168.1.20',
      port: 43521,
      expiresAt: DateTime(2100),
      receiving: true,
    );
    CompanionEndpoint? selected;
    await tester.pumpWidget(_app(endpoints: [endpoint], onSelect: (value) => selected = value));
    expect(find.text('192.168.1.20:43521'), findsOneWidget);
    expect(find.text('还没有发现电视'), findsNothing);
    await tester.tap(find.byKey(const Key('companion-cast-device-living-room')));
    expect(selected, same(endpoint));

    await tester.pumpWidget(_app(error: '网络暂时不可用'));
    expect(find.text('暂时无法搜索'), findsOneWidget);
    expect(find.text('网络暂时不可用'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('companion-cast-retry'))).onPressed, isNotNull);
  });

  for (final size in [const Size(390, 844), const Size(320, 568), const Size(844, 390)]) {
    testWidgets('picker scrolls within $size with enlarged text and bottom inset', (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _app(
          media: MediaQueryData(size: size, textScaler: TextScaler.linear(1.6), padding: const EdgeInsets.only(bottom: 24)),
        ),
      );
      expect(tester.takeException(), isNull);
      final retry = find.byKey(const Key('companion-cast-retry'));
      await tester.ensureVisible(retry);
      expect(retry.hitTestable(), findsOneWidget);
      final rect = tester.getRect(retry);
      expect(rect.bottom, lessThanOrEqualTo(size.height - 24));
      expect(tester.takeException(), isNull);
    });
  }
}

Widget _app({
  bool loading = false,
  String? error,
  List<CompanionEndpoint> endpoints = const [],
  ValueChanged<CompanionEndpoint>? onSelect,
  VoidCallback? onManual,
  VoidCallback? onRetry,
  VoidCallback? onClose,
  MediaQueryData? media,
}) => MaterialApp(
  home: Builder(
    builder: (context) => MediaQuery(
      data: media ?? MediaQuery.of(context),
      child: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: VideoTvPickerSheet(
            loading: loading,
            error: error,
            endpoints: endpoints,
            onSelect: onSelect ?? (_) {},
            onManual: onManual ?? () {},
            onRetry: onRetry ?? () {},
            onClose: onClose ?? () {},
          ),
        ),
      ),
    ),
  ),
);
