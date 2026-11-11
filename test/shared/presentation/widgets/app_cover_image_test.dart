/// 验证封面字节就绪后的解码等待、失败降级、静态等待与不阻塞外层布局。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/shared/presentation/widgets/app_cover_image.dart';
import 'package:mg_read/shared/presentation/widgets/default_content_cover_artwork.dart';

import '../../../support/visual_evidence.dart';

void main() {
  testWidgets('cover state visual evidence uses the production feedback and artwork', (tester) async {
    await loadVisualEvidenceFonts();
    tester.view.physicalSize = const Size(760, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Widget artwork() => const DefaultContentCoverArtwork(
      kind: DefaultCoverKind.novel,
      title: '封面示例',
      width: 112,
      height: 168,
      startColor: Color(0xFF263B63),
      endColor: Color(0xFF6E4D82),
      foregroundColor: Colors.white,
      borderRadius: BorderRadius.all(Radius.circular(8)),
    );
    Widget sample(String title, Widget child) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(width: 112, height: 168, child: child),
        ),
        const SizedBox(height: 12),
        Text(title),
      ],
    );
    await tester.pumpWidget(
      visualEvidenceHost(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          home: Scaffold(
            body: Center(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  sample('加载中', AppCoverFeedback(state: AppCoverState.loading, label: '封面', child: artwork())),
                  sample(
                    '已加载',
                    AppCoverImage(
                      image: const AssetImage('assets/fixtures/home_covers/lord_of_mysteries.png'),
                      placeholder: artwork(),
                      label: '封面',
                    ),
                  ),
                  sample('没有封面', AppCoverFeedback(state: AppCoverState.missing, label: '封面', child: artwork())),
                  sample('加载失败', AppCoverFeedback(state: AppCoverState.failed, label: '封面', child: artwork())),
                  MediaQuery(
                    data: const MediaQueryData(disableAnimations: true),
                    child: sample('无动画模式', AppCoverFeedback(state: AppCoverState.loading, label: '封面', child: artwork())),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => precacheImage(const AssetImage('assets/fixtures/home_covers/lord_of_mysteries.png'), tester.element(find.byType(MaterialApp))),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    expect(find.descendant(of: find.byType(AppCoverImage), matching: find.byType(DefaultContentCoverArtwork)), findsNothing);
    await captureVisualEvidence(tester, 'unified-cover-states');
  });
  testWidgets('keeps a visible loading placeholder until the first decoded frame', (tester) async {
    final image = _PendingImage();
    await tester.pumpWidget(_host(image: image));
    expect(find.byKey(const Key('cover-load-progress')), findsOneWidget);
    expect(find.text('周围的列表已经可用'), findsOneWidget);
    expect(tester.getSize(find.byKey(const Key('cover-box'))), const Size(100, 150));
    expect(tester.getSemantics(find.byType(AppCoverFeedback)).label, '测试封面加载中');
    await tester.runAsync(() async => image.frame.complete(ImageInfo(image: await createTestImage(width: 20, height: 30))));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('cover-load-progress')), findsNothing);
    expect(find.byKey(const Key('cover-placeholder')), findsNothing);
    expect(tester.getSemantics(find.byType(AppCoverFeedback)).label, '测试封面');
    expect(tester.getSize(find.byKey(const Key('cover-box'))), const Size(100, 150));
  });

  testWidgets('decode failures keep artwork and expose a distinct failure state', (tester) async {
    final image = _PendingImage();
    await tester.pumpWidget(_host(image: image));
    image.frame.completeError(StateError('invalid image bytes'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('cover-placeholder')), findsOneWidget);
    expect(find.byKey(const Key('cover-load-failed')), findsOneWidget);
    expect(find.byKey(const Key('cover-load-progress')), findsNothing);
    expect(tester.getSemantics(find.byType(AppCoverFeedback)).label, '测试封面加载失败');
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing covers remain stable and never advertise an endless load', (tester) async {
    await tester.pumpWidget(_host());
    expect(find.byKey(const Key('cover-placeholder')), findsOneWidget);
    expect(find.byKey(const Key('cover-load-progress')), findsNothing);
    expect(find.byKey(const Key('cover-load-failed')), findsNothing);
    expect(tester.getSemantics(find.byType(AppCoverFeedback)).label, '测试封面占位图');
  });

  testWidgets('no-animation mode retains static loading feedback and reveals decoded content immediately', (tester) async {
    final image = _PendingImage();
    await tester.pumpWidget(_host(image: image, disabled: true));
    expect(find.byKey(const Key('cover-load-static')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.runAsync(() async => image.frame.complete(ImageInfo(image: await createTestImage(width: 20, height: 30))));
    await tester.pump();
    expect(find.byKey(const Key('cover-load-static')), findsNothing);
    expect(find.byKey(const Key('cover-placeholder')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing motion policy while waiting does not restart the image request', (tester) async {
    final image = _PendingImage();
    await tester.pumpWidget(_host(image: image));
    await tester.pumpWidget(_host(image: image, disabled: true));
    expect(find.byKey(const Key('cover-load-static')), findsOneWidget);
    expect(image.loadCount, 1);
  });
}

Widget _host({ImageProvider? image, bool disabled = false}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: disabled),
    child: Scaffold(
      body: Column(
        children: [
          const Text('周围的列表已经可用'),
          SizedBox(
            key: const Key('cover-box'),
            width: 100,
            height: 150,
            child: AppCoverImage(
              image: image,
              label: '测试封面',
              placeholder: const ColoredBox(key: Key('cover-placeholder'), color: Colors.orange),
            ),
          ),
        ],
      ),
    ),
  ),
);

class _PendingImage extends ImageProvider<_PendingImage> {
  final frame = Completer<ImageInfo>();
  int loadCount = 0;

  @override
  Future<_PendingImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_PendingImage key, ImageDecoderCallback decode) {
    loadCount++;
    return OneFrameImageStreamCompleter(frame.future);
  }
}
