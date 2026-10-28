import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader_ui/src/api/models.dart';
import 'package:novel_reader_ui/src/core/auto_reading_coordinator.dart';
import 'package:novel_reader_ui/src/platform/reader_platform.dart';
import 'package:novel_reader_ui/src/ui/reader_strings.dart';
import 'package:novel_reader_ui/src/ui/reader_theme.dart';
import 'package:novel_reader_ui/src/ui/settings/reader_settings_controls.dart';
import 'package:novel_reader_ui/src/ui/settings/reader_settings_font_size_control.dart';
import 'package:novel_reader_ui/src/ui/settings/reader_settings_sheet.dart';

void main() {
  testWidgets(
    'layout preview resets typography while retaining reading preferences',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      TextReaderPreferences? committed;
      final initial = TextReaderPreferences.defaults.copyWith(
        fontSize: 28,
        lineHeight: 2.1,
        theme: ReaderThemePreset.parchment,
        brightness: .4,
        background: ReaderBackgroundPreset.ricePaper,
      );
      await tester.pumpWidget(
        _host(preferences: initial, onCommit: (value) => committed = value),
      );
      await tester.pumpAndSettle();
      expect(find.text('纸张颜色'), findsOneWidget);
      expect(find.text('纸张纹理'), findsOneWidget);
      await tester.ensureVisible(find.text(ReaderStrings.spacingSettings));
      await tester.tap(find.text(ReaderStrings.spacingSettings));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('reader-layout-preview')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('reader-reset-layout')));
      await tester.pumpAndSettle();
      expect(committed!.fontSize, TextReaderPreferences.defaults.fontSize);
      expect(committed!.lineHeight, TextReaderPreferences.defaults.lineHeight);
      expect(committed!.theme, initial.theme);
      expect(committed!.background, initial.background);
      expect(committed!.brightness, initial.brightness);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('font controls share one adaptive row with a section label', (
    WidgetTester tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(360, 500));
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    final Finder sizeControl = find.byType(ReaderSettingsFontSizeControl);
    final Finder fontControl = find.ancestor(
      of: find.text(ReaderStrings.miSans),
      matching: find.byType(ReaderSettingsCapsule),
    );
    final Rect sizeRect = tester.getRect(sizeControl);
    final Rect fontRect = tester.getRect(fontControl);

    expect(find.text(ReaderStrings.fontSize), findsOneWidget);
    expect(sizeRect.top, fontRect.top);
    expect(sizeRect.height, fontRect.height);
    expect(sizeRect.width, closeTo(fontRect.width, 1));
    expect(fontRect.right, lessThanOrEqualTo(360));

    await tester.binding.setSurfaceSize(const Size(600, 500));
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    final Finder resizedFontControl = find.ancestor(
      of: find.text(ReaderStrings.miSans),
      matching: find.byType(ReaderSettingsCapsule),
    );
    expect(
      tester.getRect(resizedFontControl).width,
      greaterThan(fontRect.width),
    );

    await tester.tap(resizedFontControl);
    await tester.pumpAndSettle();
    expect(find.text(ReaderStrings.fontSize), findsOneWidget);
  });
}

Widget _host({
  TextReaderPreferences preferences = TextReaderPreferences.defaults,
  ValueChanged<TextReaderPreferences>? onCommit,
}) {
  return MaterialApp(
    home: ReaderSettingsSheet(
      preferences: preferences,
      palette: ReaderPalette.fromPreset(ReaderThemePreset.day),
      platformCapabilities: const ReaderPlatformCapabilities(),
      commentsAvailable: false,
      autoReading: false,
      autoReadingPace: ReaderAutoReadingPace.normal,
      layoutDebugMode: false,
      fontRepository: null,
      onCustomFontSelected: (ReaderFontDescriptor _, String _) async {},
      onFontError: (_) {},
      onPreferencesPreview: (_) {},
      onPreferencesCommit: onCommit ?? (_) {},
      onAutoReadingChanged: (_) {},
      onAutoReadingPaceChanged: (_) {},
      onLayoutDebugModeChanged: (_) {},
      onCatalogPressed: () {},
      onBookmarksPressed: () {},
    ),
  );
}
