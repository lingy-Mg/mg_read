/// Production full audio navigator and both mini-player styles; fake I/O only.
part of 'source_audio_playback_host_test.dart';

void _registerSourceAudioVisualEvidence() {
  for (final dark in [false, true]) {
    testWidgets('production audio full settings and mini evidence ${dark ? 'dark' : 'light'}', (tester) async {
      await loadVisualEvidenceFonts();
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final settings = AppSettingsManager(store: FakeSettingsStore(), registry: AppSettingKeys.registry);
      await settings.initialize();
      addTearDown(settings.close);
      final backend = _FakeAudioBackend();
      final dispatcher = RootBackButtonDispatcher();
      Future<bool> routerFallback() async => false;
      dispatcher.addCallback(routerFallback);
      addTearDown(() => dispatcher.removeCallback(routerFallback));
      late WidgetRef rootRef;
      await tester.pumpWidget(
        visualEvidenceHost(
          ProviderScope(
            overrides: [
              appSettingsProvider.overrideWithValue(settings),
              sourceContentGatewayProvider.overrideWithValue(_AudioGateway(_request())),
              sourceAudioPlaybackBackendFactoryProvider.overrideWithValue(() => backend),
            ],
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: dark ? AppTheme.dark() : AppTheme.light(),
              home: const Scaffold(body: Center(child: Text('本地测试书架'))),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: true),
                child: Consumer(
                  builder: (context, ref, _) {
                    rootRef = ref;
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        child!,
                        SourceAudioPlaybackNavigator(backButtonDispatcher: dispatcher),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      final service = rootRef.read(sourceAudioPlaybackServiceProvider.notifier);
      final playback = service.open(_request());
      await _pumpUntil(tester, () => find.byKey(const Key('audio-back')).evaluate().isNotEmpty);
      await tester.pump(const Duration(milliseconds: 400));
      await settleVisualEvidenceImages(tester);
      await captureVisualEvidence(tester, 'audio-${dark ? 'dark' : 'light'}-full');
      await tester.tap(find.byKey(const Key('audio-settings')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('audio-rate')), findsOneWidget);
      final close = find.byKey(const Key('audio-settings-close'));
      expect(tester.widget<IconButton>(close).onPressed, isNotNull);
      expect((Offset.zero & tester.view.physicalSize).contains(tester.getRect(close).center), isTrue);
      await captureVisualEvidence(tester, 'audio-${dark ? 'dark' : 'light'}-settings');
      await tester.tap(find.byKey(const Key('audio-settings-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('audio-settings-sheet')), findsNothing);
      service.minimize(rootRef.read(sourceAudioPlaybackServiceProvider).sessionId!);
      await _pumpUntil(tester, () => find.byKey(const Key('source-audio-mini-player')).evaluate().isNotEmpty);
      for (final style in ['bar', 'square']) {
        await settings.set(AppSettingKeys.audioMiniPlayerStyle, style);
        await tester.pump(const Duration(milliseconds: 400));
        _expectMiniControlsSeparate(tester);
        await captureVisualEvidence(tester, 'audio-${dark ? 'dark' : 'light'}-mini-$style');
      }
      expect(backend.openCalls, 1);
      await service.stop();
      await playback;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 400));
    });
  }
}
