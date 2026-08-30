import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/profile/application/profile_identity_store.dart';
import 'package:mg_read/features/profile/domain/profile_identity.dart';

import '../../../core/settings/settings_testkit.dart';

void main() {
  test('persists local profile identity across settings manager restarts', () async {
    final store = FakeSettingsStore();
    final first = AppSettingsManager(
      store: store,
      registry: AppSettingKeys.registry,
      policy: const SettingsPersistencePolicy(debounce: Duration.zero),
    );
    await first.initialize();

    const changed = ProfileIdentity(displayName: '纸间旅人', motto: '在每一页里遇见新的世界。');
    await ProfileIdentityStore(first).save(changed);
    await first.close();

    final second = AppSettingsManager(
      store: store,
      registry: AppSettingKeys.registry,
      policy: const SettingsPersistencePolicy(debounce: Duration.zero),
    );
    await second.initialize();
    addTearDown(second.close);

    expect(ProfileIdentityStore(second).read(), changed);
    expect(
      store.documents[AppSettingKeys.profileDocument.kind]!.values,
      containsPair(AppSettingKeys.profileIdentity.id, changed.toSettingValue()),
    );
  });

  test('production setting key rejects blank or oversized profile values', () {
    expect(
      () => AppSettingKeys.profileIdentity.validateValue(const <String, Object?>{'displayName': ' ', 'motto': '本地签名'}),
      throwsArgumentError,
    );
    expect(
      () => AppSettingKeys.profileIdentity.validateValue(<String, Object?>{
        'displayName': '本地读者',
        'motto': List<String>.filled(51, '字').join(),
      }),
      throwsArgumentError,
    );
  });

  test('rolls visible identity back when durable persistence fails', () async {
    final store = FakeSettingsStore()..failWrites = 2;
    final manager = AppSettingsManager(
      store: store,
      registry: AppSettingKeys.registry,
      policy: const SettingsPersistencePolicy(debounce: Duration.zero, flushRetryAttempts: 1),
    );
    await manager.initialize();
    addTearDown(manager.close);

    await expectLater(ProfileIdentityStore(manager).save(const ProfileIdentity(displayName: '未落盘资料', motto: '这次写入会失败。')), throwsStateError);

    expect(ProfileIdentityStore(manager).read(), ProfileIdentity.defaults);
  });
}
