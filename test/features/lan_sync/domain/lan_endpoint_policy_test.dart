import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/features/lan_sync/domain/lan_endpoint_policy.dart';

void main() {
  test('normalizes private LAN candidates once for every LAN protocol', () {
    expect(normalizeLanSyncAddresses(const <String>['192.168.1.20', '10.0.0.8', '192.168.1.20']), const <String>[
      '192.168.1.20',
      '10.0.0.8',
    ]);
    expect(isLanSyncPrivateIpv4('172.16.0.1'), isTrue);
    expect(isLanSyncPrivateIpv4('172.31.255.255'), isTrue);
  });

  test('rejects empty, public, loopback and excessive candidate lists', () {
    expect(() => normalizeLanSyncAddresses(const <String>[]), throwsArgumentError);
    expect(() => normalizeLanSyncAddresses(const <String>['8.8.8.8']), throwsArgumentError);
    expect(() => normalizeLanSyncAddresses(const <String>['127.0.0.1']), throwsArgumentError);
    expect(() => normalizeLanSyncAddresses(List<String>.generate(17, (index) => '10.0.0.${index + 1}')), throwsArgumentError);
  });
}
