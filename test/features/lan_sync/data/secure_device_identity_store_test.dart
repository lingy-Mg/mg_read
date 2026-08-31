import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/features/lan_sync/data/secure_device_identity_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('migrates a persisted localhost placeholder to the silent Android model label', () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'mgread.device-sync.device-id.v1': 'device_identity_123456',
      'mgread.device-sync.device-label.v1': 'localhost',
    });
    const storage = FlutterSecureStorage();
    final identity = await SecureDeviceIdentityStore(
      storage: storage,
      deviceLabelResolver: () async => 'Google   Pixel 9 Pro',
    ).loadOrCreateIdentity();
    expect(identity.label, 'Google Pixel 9 Pro');
    expect(await storage.read(key: 'mgread.device-sync.device-label.v1'), identity.label);
  });

  test('falls back without failing identity startup when the platform channel is unavailable', () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'mgread.device-sync.device-id.v1': 'device_identity_123456',
      'mgread.device-sync.device-label.v1': 'localhost',
    });
    const storage = FlutterSecureStorage();
    final identity = await SecureDeviceIdentityStore(
      storage: storage,
      deviceLabelResolver: () async => throw StateError('channel unavailable'),
    ).loadOrCreateIdentity();

    expect(identity.label.toLowerCase(), isNot('localhost'));
  });
}
