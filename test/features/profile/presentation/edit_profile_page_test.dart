import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/profile/domain/profile_identity.dart';
import 'package:mg_read/features/profile/presentation/edit_profile_page.dart';

import '../../../core/settings/settings_testkit.dart';

void main() {
  testWidgets('loads, edits, and durably saves the local profile', (WidgetTester tester) async {
    final store = FakeSettingsStore();
    final settings = AppSettingsManager(
      store: store,
      registry: AppSettingKeys.registry,
      policy: const SettingsPersistencePolicy(debounce: Duration.zero),
    );
    await settings.initialize();
    addTearDown(settings.close);
    var backRequests = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appSettingsProvider.overrideWithValue(settings)],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: EditProfilePage(onBackRequested: () => backRequests++),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('仅当前设备可见'), findsOneWidget);
    expect(find.text('书海行者'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('edit-profile-display-name')), '纸间旅人');
    await tester.enterText(find.byKey(const Key('edit-profile-motto')), '在每一页里遇见新的世界。');
    await tester.tap(find.byKey(const Key('edit-profile-save')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(backRequests, 1);
    expect(
      ProfileIdentity.fromSettingValue(settings.get(AppSettingKeys.profileIdentity)),
      const ProfileIdentity(displayName: '纸间旅人', motto: '在每一页里遇见新的世界。'),
    );
    expect(store.documents[AppSettingKeys.profileDocument.kind], isNotNull);
  });

  testWidgets('keeps the page open when required fields are blank', (WidgetTester tester) async {
    final settings = AppSettingsManager(store: FakeSettingsStore(), registry: AppSettingKeys.registry);
    await settings.initialize();
    addTearDown(settings.close);
    var backRequests = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appSettingsProvider.overrideWithValue(settings)],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: EditProfilePage(onBackRequested: () => backRequests++),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('edit-profile-display-name')), '   ');
    await tester.tap(find.byKey(const Key('edit-profile-save')));
    await tester.pump();

    expect(find.text('昵称不能为空'), findsOneWidget);
    expect(backRequests, 0);
  });
}
