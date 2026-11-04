import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/tv_companion/application/companion_controller.dart';
import 'package:mg_read/features/tv_companion/presentation/companion_history_page.dart';

void main() {
  testWidgets('offline history exposes both device branches and resumes the explicitly selected local record', (tester) async {
    tester.view.physicalSize = const Size(480, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = await tester.runAsync(() => Directory.systemTemp.createTemp('companion-history-ui-'));
    expect(directory, isNotNull);
    final library = await tester.runAsync(() async {
      final opened = await ContentLibrary.open(dataRoot: directory!);
      await opened.saveVideoHistory(_checkpoint(contentId: 'resume-a', origin: 'tv-device-000001', session: 'session-a', order: 1));
      await opened.saveVideoHistory(_checkpoint(contentId: 'resume-b', origin: 'tv-device-000002', session: 'session-b', order: 2));
      return opened;
    });
    expect(library, isNotNull);
    addTearDown(() async {
      await library!.close();
      await directory!.delete(recursive: true);
    });

    VideoHistoryCheckpoint? resumed;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          companionLibraryProvider.overrideWithValue(() async => library!),
          companionLocalResumeLauncherProvider.overrideWithValue((checkpoint) async => resumed = checkpoint),
        ],
        child: MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.35)),
            child: const CompanionHistoryPage(),
          ),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    expect(find.text('本机与 TV 观看记录'), findsOneWidget);
    for (final label in ['其他设备 · 000001 · 1:30 / 10:00', '其他设备 · 000002 · 1:30 / 10:00']) {
      await tester.scrollUntilVisible(find.text(label), 100, scrollable: find.byType(Scrollable).first);
      expect(find.text(label), findsOneWidget);
      final card = find.ancestor(of: find.text(label), matching: find.byType(Card));
      final tvButton = tester.widget<TextButton>(find.descendant(of: card, matching: find.widgetWithText(TextButton, '在 TV 继续')));
      expect(tvButton.onPressed, isNull);
    }

    await tester.scrollUntilVisible(find.text('其他设备 · 000002 · 1:30 / 10:00'), 100, scrollable: find.byType(Scrollable).first);
    final selectedCard = find.ancestor(of: find.text('其他设备 · 000002 · 1:30 / 10:00'), matching: find.byType(Card));
    final localResume = find.descendant(of: selectedCard, matching: find.text('在本机继续'));
    await tester.ensureVisible(localResume);
    await tester.tap(localResume);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    expect(resumed?.originDeviceId, 'tv-device-000002');
    expect(tester.takeException(), isNull);
  });
}

VideoHistoryCheckpoint _checkpoint({required String contentId, required String origin, required String session, required int order}) =>
    VideoHistoryCheckpoint(
      pluginId: 'video-source',
      contentId: contentId,
      pluginVersion: '1',
      title: 'Shared video',
      groupId: 'season-1',
      episodeId: 'episode-1',
      position: const Duration(minutes: 1, seconds: 30),
      duration: const Duration(minutes: 10),
      originDeviceId: origin,
      playbackSessionId: session,
      sequence: order,
      localGeneration: 1,
      updatedAtUtc: DateTime.utc(2026, 11, order),
    );
