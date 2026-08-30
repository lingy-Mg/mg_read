/// 本地展示资料与应用设置之间的边界。
///
/// 职责：
/// - 从内存优先的应用设置快照读取个人资料。
/// - 保存昵称与签名，并等待资料文档完成持久化。
///
/// 注意：
/// - 不创建独立数据库，也不接触 Runtime 或网络。
/// - 页面只通过此边界读写，不直接操作设置键。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/profile/domain/profile_identity.dart';

final profileIdentityStoreProvider = Provider<ProfileIdentityStore>((Ref ref) {
  return ProfileIdentityStore(ref.watch(appSettingsProvider));
});

final profileIdentityProvider = StreamProvider<ProfileIdentity>((Ref ref) async* {
  final store = ref.watch(profileIdentityStoreProvider);
  yield store.read();
  await for (final _ in store.changes) {
    yield store.read();
  }
});

final class ProfileIdentityStore {
  const ProfileIdentityStore(this._settings);

  final AppSettingsManager _settings;

  Stream<void> get changes => _settings.changes.map((_) {});

  ProfileIdentity read() {
    return ProfileIdentity.fromSettingValue(_settings.get(AppSettingKeys.profileIdentity));
  }

  Future<void> save(ProfileIdentity identity) async {
    final previous = _settings.get(AppSettingKeys.profileIdentity);
    try {
      await _settings.set(AppSettingKeys.profileIdentity, identity.toSettingValue());
      final result = await _settings.flush();
      if (result.dirtyDocumentKinds.contains(AppSettingKeys.profileDocument.kind) ||
          result.degradedDocumentKinds.contains(AppSettingKeys.profileDocument.kind)) {
        throw StateError('profile_identity_not_persisted');
      }
    } on Object {
      await _settings.set(AppSettingKeys.profileIdentity, previous);
      throw StateError('profile_identity_not_persisted');
    }
  }
}
