/// 错误链复制、窄屏滚动及剪贴板失败回退；截图仅来自测试渲染层。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';
import 'package:novel_reader_ui/src/ui/reader_failure_details.dart';

void main() {
  testWidgets(
    'long source error stays selectable and copyable on a narrow screen',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await (FontLoader(
        'Roboto',
      )..addFont(rootBundle.load('assets/fonts/MiSansVF.ttf'))).load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      String? copied;
      var unavailable = false;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            if (unavailable)
              throw PlatformException(code: 'clipboard_unavailable');
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final cause = StateError(
        'HTTP 404；章节地址：https://www.alicesw.com/book/42/first.html\n${'请求小说章节正文失败。' * 12}',
      );
      final failure = ReaderFailure(
        ReaderFailureKind.data,
        '章节正文无法加载',
        code: 'source_text_content_load_failed',
        location: '请求小说章节正文',
        cause: cause,
      );
      await tester.pumpWidget(
        RepaintBoundary(
          key: const Key('error-evidence'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ReaderFailureDetails(
                  failure: failure,
                  bookId: 'source:org.mgread.aisishuwu:novel:42',
                  bookTitle: '正文加载失败示例',
                  color: Colors.black87,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('reader-copy-error')));
      await tester.tap(find.byKey(const Key('reader-copy-error')));
      await tester.pumpAndSettle();
      expect(copied, contains('HTTP 404'));
      expect(copied, contains('source_text_content_load_failed'));
      expect(copied, contains('novel:42'));
      expect(copied, contains('/book/42/first.html'));
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('error-evidence')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        final file = File('../../.dart_tool/ai-checks/reader-error-narrow.png');
        await file.writeAsBytes(bytes!.buffer.asUint8List());
      });
      unavailable = true;
      await tester.tap(find.byKey(const Key('reader-copy-error')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(SelectableText), findsOneWidget);
    },
  );
}
