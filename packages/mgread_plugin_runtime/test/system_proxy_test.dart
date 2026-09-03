import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

void main() {
  test(
    'system proxy environment always excludes loopback destinations',
    () async {
      final environment = await readSystemProxyEnvironment();
      final noProxy = environment['NO_PROXY']!
          .split(',')
          .map((item) => item.trim())
          .toSet();

      expect(noProxy, containsAll(<String>['localhost', '127.0.0.1', '::1']));
    },
  );
}
