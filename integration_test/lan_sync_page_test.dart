import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/lan_sync/presentation/lan_sync_page.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders the light foreground LAN sync entry', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          home: LanSyncPage(
            onBackRequested: () {},
            onDestinationRequested: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('lan-sync-send')), findsOneWidget);
    expect(find.byKey(const Key('lan-sync-receive')), findsOneWidget);
    expect(find.byKey(const Key('lan-sync-receive-qr')), findsOneWidget);
    expect(find.textContaining('首版传输不加密'), findsOneWidget);

    await binding.convertFlutterSurfaceToImage();
    await tester.pump();
    await binding.takeScreenshot('lan_sync_entry_light');
  });
}
