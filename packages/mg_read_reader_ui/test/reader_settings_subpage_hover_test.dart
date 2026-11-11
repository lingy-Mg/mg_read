import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader_ui/src/api/models.dart';
import 'package:novel_reader_ui/src/core/auto_reading_coordinator.dart';
import 'package:novel_reader_ui/src/platform/reader_platform.dart';
import 'package:novel_reader_ui/src/ui/reader_strings.dart';
import 'package:novel_reader_ui/src/ui/reader_theme.dart';
import 'package:novel_reader_ui/src/ui/settings/reader_settings_sheet.dart';

void main() {
  testWidgets(
    'reduced motion switches settings pages and controls immediately',
    (tester) async {
      await tester.pumpWidget(_host(disableAnimations: true));
      await tester.pumpAndSettle();
      await tester.tap(find.text(ReaderStrings.moreSettings));
      await tester.pump();
      expect(find.byType(SwitchListTile), findsWidgets);
      for (final animated in tester.widgetList<AnimatedSwitcher>(
        find.byType(AnimatedSwitcher),
      )) {
        expect(animated.duration, Duration.zero);
      }
      for (final animated in tester.widgetList<AnimatedContainer>(
        find.byType(AnimatedContainer),
      )) {
        expect(animated.duration, Duration.zero);
      }
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('more settings switch rows clip hover feedback to their shape', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    await tester.tap(find.text(ReaderStrings.moreSettings));
    await tester.pumpAndSettle();

    final Finder switches = find.byType(SwitchListTile);
    expect(switches, findsWidgets);
    for (final Element tile in switches.evaluate()) {
      final Material material = tile.findAncestorWidgetOfExactType<Material>()!;
      expect(material.clipBehavior, Clip.antiAlias);
    }
  });
}

Widget _host({bool disableAnimations = false}) {
  return MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(disableAnimations: disableAnimations),
      child: child!,
    ),
    home: ReaderSettingsSheet(
      preferences: TextReaderPreferences.defaults,
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
      onPreferencesCommit: (_) {},
      onAutoReadingChanged: (_) {},
      onAutoReadingPaceChanged: (_) {},
      onLayoutDebugModeChanged: (_) {},
      onCatalogPressed: () {},
      onBookmarksPressed: () {},
    ),
  );
}
