part of 'reader_settings_sheet.dart';

Future<void> showReaderSettingsSheet({
  required BuildContext context,
  required TextReaderPreferences preferences,
  required ReaderPalette palette,
  required ReaderPlatformCapabilities platformCapabilities,
  required bool commentsAvailable,
  required bool autoReading,
  required ReaderAutoReadingPace autoReadingPace,
  required ReaderThemePreset lastNonNightTheme,
  required ReaderFontRepository? fontRepository,
  required FutureOr<void> Function(
    ReaderFontDescriptor descriptor,
    String runtimeFamily,
  )
  onCustomFontSelected,
  required ValueChanged<Object> onFontError,
  required ValueChanged<TextReaderPreferences> onPreferencesPreview,
  required ValueChanged<TextReaderPreferences> onPreferencesCommit,
  required ValueChanged<bool> onAutoReadingChanged,
  required ValueChanged<ReaderAutoReadingPace> onAutoReadingPaceChanged,
  required VoidCallback onCatalogPressed,
  required VoidCallback onBookmarksPressed,
  VoidCallback? onDismissed,
}) {
  TextReaderPreferences latestPreferences = preferences.normalized();
  bool hasPendingPreview = false;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    isDismissible: true,
    // Settings are dismissed by tapping the modal barrier or using the
    // platform back action. Do not let a vertical drag move the reader or
    // dismiss the settings surface accidentally.
    enableDrag: false,
    useSafeArea: false,
    backgroundColor: Colors.transparent,
    barrierColor: ReaderSettingsTokens.sheetBarrier(palette),
    builder: (BuildContext context) {
      final double height =
          (MediaQuery.sizeOf(context).height *
                  ReaderSettingsTokens.sheetHeightFactor)
              .clamp(0, ReaderSettingsTokens.maxDesktopSheetHeight)
              .toDouble();
      // Keep the route child limited to the visible sheet. A full-height Align
      // would cover the modal barrier with a transparent BottomSheet surface,
      // preventing outside taps from dismissing the sheet.
      return SizedBox(
        width: double.infinity,
        height: height,
        child: ReaderSettingsSheet(
          preferences: preferences,
          palette: palette,
          platformCapabilities: platformCapabilities,
          commentsAvailable: commentsAvailable,
          autoReading: autoReading,
          autoReadingPace: autoReadingPace,
          lastNonNightTheme: lastNonNightTheme,
          fontRepository: fontRepository,
          onCustomFontSelected: onCustomFontSelected,
          onFontError: onFontError,
          onPreferencesPreview: (TextReaderPreferences value) {
            latestPreferences = value.normalized();
            hasPendingPreview = true;
            onPreferencesPreview(latestPreferences);
          },
          onPreferencesCommit: (TextReaderPreferences value) {
            latestPreferences = value.normalized();
            hasPendingPreview = false;
            onPreferencesCommit(latestPreferences);
          },
          onAutoReadingChanged: onAutoReadingChanged,
          onAutoReadingPaceChanged: onAutoReadingPaceChanged,
          onCatalogPressed: onCatalogPressed,
          onBookmarksPressed: onBookmarksPressed,
        ),
      );
    },
  ).whenComplete(() {
    // A route can be dismissed while a Slider gesture is still active. Flush
    // exactly its latest preview rather than losing it or persisting every
    // intermediate drag value.
    if (hasPendingPreview) onPreferencesCommit(latestPreferences);
    onDismissed?.call();
  });
}

class ReaderSettingsSheet extends StatefulWidget {
  const ReaderSettingsSheet({
    super.key,
    required this.preferences,
    required this.palette,
    required this.platformCapabilities,
    required this.commentsAvailable,
    required this.autoReading,
    required this.autoReadingPace,
    required this.lastNonNightTheme,
    required this.fontRepository,
    required this.onCustomFontSelected,
    required this.onFontError,
    required this.onPreferencesPreview,
    required this.onPreferencesCommit,
    required this.onAutoReadingChanged,
    required this.onAutoReadingPaceChanged,
    required this.onCatalogPressed,
    required this.onBookmarksPressed,
  });

  final TextReaderPreferences preferences;
  final ReaderPalette palette;
  final ReaderPlatformCapabilities platformCapabilities;
  final bool commentsAvailable;
  final bool autoReading;
  final ReaderAutoReadingPace autoReadingPace;
  final ReaderThemePreset lastNonNightTheme;
  final ReaderFontRepository? fontRepository;
  final FutureOr<void> Function(
    ReaderFontDescriptor descriptor,
    String runtimeFamily,
  )
  onCustomFontSelected;
  final ValueChanged<Object> onFontError;
  final ValueChanged<TextReaderPreferences> onPreferencesPreview;
  final ValueChanged<TextReaderPreferences> onPreferencesCommit;
  final ValueChanged<bool> onAutoReadingChanged;
  final ValueChanged<ReaderAutoReadingPace> onAutoReadingPaceChanged;
  final VoidCallback onCatalogPressed;
  final VoidCallback onBookmarksPressed;

  @override
  State<ReaderSettingsSheet> createState() => _ReaderSettingsSheetState();
}

enum _SettingsPage { main, font, spacing, comments, more }

enum _PagingChoice { pageCurl, cover, slide, vertical, none }
