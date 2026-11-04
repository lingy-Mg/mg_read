/// Covered settings must not block control of a newly visible player route.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/tv_companion/application/companion_controller.dart';

void main() {
  test('only visible protected owners block remote navigation', () {
    final guard = CompanionNavigationGuard(), settings = Object(), other = Object();
    var current = true;
    guard.enter(settings, isCurrent: () => current);
    expect(guard.protected, isTrue);
    current = false;
    expect(guard.protected, isFalse);
    guard.enter(other);
    expect(guard.protected, isTrue);
    guard.leave(other);
    expect(guard.protected, isFalse);
    current = true;
    expect(guard.protected, isTrue);
    guard.leave(settings);
    expect(guard.protected, isFalse);
  });
}
