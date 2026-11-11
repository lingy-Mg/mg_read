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
  testWidgets('fullscreen media keeps a dark loading canvas in a light app theme', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: const Scaffold(
            body: SizedBox(
              width: 100,
              height: 150,
              child: AppCoverFeedback(
                state: AppCoverState.loading,
                label: '播放器封面',
                loadingBaseColor: Colors.black,
                child: ColoredBox(color: Colors.orange),
              ),
            ),
          ),
        ),
      ),
    );
    final decoration =
        tester.widget<DecoratedBox>(find.descendant(of: find.byType(AppCoverFeedback), matching: find.byType(DecoratedBox))).decoration
            as BoxDecoration;
    expect(decoration.gradient!.colors.every((color) => ThemeData.estimateBrightnessForColor(color) == Brightness.dark), isTrue);
  });

  testWidgets('loading sheen stops for hidden routes and disabled motion', (tester) async {
    Widget host({required bool tickers, bool disabled = false}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: disabled),
        child: TickerMode(
          enabled: tickers,
          child: const Scaffold(
            body: SizedBox(
              width: 100,
              height: 150,
              child: AppCoverFeedback(
                state: AppCoverState.loading,
                label: '测试封面',
                child: ColoredBox(color: Colors.orange),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(host(tickers: true));
    await tester.pump(AppMotion.coverLoadingDelay);
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.pumpWidget(host(tickers: false));
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(host(tickers: true, disabled: true));
    await tester.pump();
    expect(find.byKey(const Key('cover-load-static')), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('refreshing artwork stays visible without a central spinner or scrim', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 100,
            height: 150,
            child: AppCoverFeedback(
              state: AppCoverState.refreshing,
              label: '旧封面',
              child: const ColoredBox(key: Key('existing-artwork'), color: Colors.blue),
            ),
          ),
        ),
      ),
    );
    expect(
      tester.widget<Opacity>(find.ancestor(of: find.byKey(const Key('existing-artwork')), matching: find.byType(Opacity)).first).opacity,
      1,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(Icon), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('replacing decoded artwork keeps the old frame and does not flash a skeleton on success', (tester) async {
    final first = _PendingImage();
    final replacement = _PendingImage();
    await tester.pumpWidget(_host(image: first));
    await tester.runAsync(() async => first.frame.complete(ImageInfo(image: await createTestImage(width: 20, height: 30))));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_host(image: replacement));
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    expect(find.byKey(const Key('cover-placeholder')), findsNothing);
    expect(tester.widget<AppCoverFeedback>(find.byType(AppCoverFeedback)).state, AppCoverState.refreshing);
    await tester.runAsync(() async {
      replacement.frame.complete(ImageInfo(image: await createTestImage(width: 40, height: 60)));
    });
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('cover-placeholder')), findsNothing);
    expect(find.byType(TweenAnimationBuilder<double>), findsNothing);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image!.width, 40);
    expect(tester.widget<AppCoverFeedback>(find.byType(AppCoverFeedback)).state, AppCoverState.ready);
  });

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
    Widget scene(ThemeData theme) => visualEvidenceHost(
      MaterialApp(
        key: ValueKey(theme.brightness),
        debugShowCheckedModeBanner: false,
        theme: theme,
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
    );
    await tester.pumpWidget(scene(AppTheme.light()));
    await tester.runAsync(
      () => precacheImage(const AssetImage('assets/fixtures/home_covers/lord_of_mysteries.png'), tester.element(find.byType(MaterialApp))),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    expect(find.descendant(of: find.byType(AppCoverImage), matching: find.byType(DefaultContentCoverArtwork)), findsNothing);
    await tester.pump(AppMotion.coverLoadingSweep * .36);
    await captureVisualEvidence(tester, 'cover-loading-polish-light');
    await tester.pumpWidget(scene(AppTheme.dark()));
    await tester.pump(AppMotion.coverLoadingDelay);
    await tester.pump(AppMotion.coverLoadingSweep * .36);
    await captureVisualEvidence(tester, 'cover-loading-polish-dark');
  });
  testWidgets('keeps a visible loading placeholder until the first decoded frame', (tester) async {
    final image = _PendingImage();
    await tester.pumpWidget(_host(image: image));
    expect(find.byKey(const Key('cover-load-progress')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('周围的列表已经可用'), findsOneWidget);
    expect(tester.getSize(find.byKey(const Key('cover-box'))), const Size(100, 150));
    expect(tester.getSemantics(find.byType(AppCoverFeedback)).label, '测试封面加载中');
    await tester.runAsync(() async => image.frame.complete(ImageInfo(image: await createTestImage(width: 20, height: 30))));
    await tester.pump();
    expect(
      find.byKey(const Key('cover-placeholder')),
      findsNothing,
      reason: 'The loaded image fades from the neutral skeleton, without flashing fallback artwork.',
    );
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
