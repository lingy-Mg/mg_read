/// Direct URL input validation for the Bilibili discovery playback page.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/features/discovery/presentation/bilibili_url_playback_page.dart';

void main() {
  testWidgets('asks for a Bilibili audio URL or BV ID before loading', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BilibiliUrlPlaybackPage(
          onAudioChapterRequested: ({required detail, required firstCatalogPage, required chapter, required pluginVersion}) async {},
        ),
      ),
    );

    await tester.enterText(find.byKey(const Key('bilibili-url-input')), 'not a video link');
    await tester.tap(find.byKey(const Key('bilibili-url-submit')));
    await tester.pump();

    expect(find.text('请输入有效的 B 站视频链接或 BV 号。'), findsOneWidget);
    expect(find.byKey(const Key('bilibili-url-error')), findsOneWidget);
  });
}
