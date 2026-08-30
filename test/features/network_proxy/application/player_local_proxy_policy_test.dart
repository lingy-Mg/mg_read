import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/network_proxy/application/player_local_proxy_policy.dart';

void main() {
  test('removes only Runtime loopback matches from NO_PROXY', () {
    expect(stripLoopbackFromNoProxy('localhost,127.0.0.1,127.0.0.1:59964,::1,[::1],example.com,.internal'), 'example.com,.internal');
    expect(stripLoopbackFromNoProxy('*'), isNull);
  });

  test('force and restore write a reversible native environment value', () {
    final writes = <({String name, String? value})>[];
    final controller = PlayerLocalProxyPolicyController.forTesting(
      'localhost,127.0.0.1,example.com',
      true,
      (name, value) => writes.add((name: name, value: value)),
    );

    controller.setForced(true);
    controller.setForced(true);
    controller.restore();

    expect(writes, <({String name, String? value})>[
      (name: 'no_proxy', value: 'example.com'),
      (name: 'no_proxy', value: 'localhost,127.0.0.1,example.com'),
    ]);
    expect(controller.isForcing, isFalse);
  });

  test('unsupported platforms never mutate their process environment', () {
    final writes = <Object?>[];
    final controller = PlayerLocalProxyPolicyController.forTesting('127.0.0.1', false, (name, value) => writes.add((name, value)));

    controller.setForced(true);

    expect(controller.isForcing, isFalse);
    expect(writes, isEmpty);
  });

  test('Windows controller updates both CRT environments used by native FFmpeg and restores them', () {
    if (!Platform.isWindows) return;
    final original = readWindowsCrtEnvironment('no_proxy');
    final controller = PlayerLocalProxyPolicyController();
    try {
      controller.setForced(true);
      final forced = readWindowsCrtEnvironment('no_proxy');
      expect(forced.keys, containsAll(<String>['ucrtbase.dll', 'msvcrt.dll']));
      expect(forced.values, everyElement(anyOf(isNull, isNot(contains('127.0.0.1')))));
    } finally {
      controller.restore();
    }
    expect(readWindowsCrtEnvironment('no_proxy'), original);
  });
}
