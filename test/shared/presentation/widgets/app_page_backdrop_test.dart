import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/shared/presentation/widgets/app_page_backdrop.dart';

void main() {
  testWidgets('renders the matching decorative asset for every primary tab', (
    WidgetTester tester,
  ) async {
    const Map<AppPageBackdropStyle, String> expectedAssets =
        <AppPageBackdropStyle, String>{
          AppPageBackdropStyle.home:
              'assets/illustrations/page_backdrops/home_paper.png',
          AppPageBackdropStyle.search:
              'assets/illustrations/page_backdrops/search_index.png',
          AppPageBackdropStyle.discover:
              'assets/illustrations/page_backdrops/discover_horizon.png',
          AppPageBackdropStyle.profile:
              'assets/illustrations/page_backdrops/profile_bookmark.png',
        };

    for (final MapEntry<AppPageBackdropStyle, String> entry
        in expectedAssets.entries) {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: AppPageBackdrop(
            style: entry.key,
            child: const SizedBox(key: Key('page-content')),
          ),
        ),
      );

      expect(find.byKey(const Key('page-content')), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      final Image image = tester.widget<Image>(find.byType(Image));
      expect((image.image as AssetImage).assetName, entry.value);
    }
  });
}
