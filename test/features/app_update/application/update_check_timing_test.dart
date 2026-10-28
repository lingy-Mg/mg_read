import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/app_update/application/update_check_result.dart';

void main() {
  test('failure retries use 1, 5, 30 minutes without updating success', () {
    final timing = AutomaticCheckTiming();
    var now = DateTime.utc(2026, 10, 28);
    for (final minutes in [1, 5, 30, 30]) {
      timing.complete(now, success: false);
      expect(timing.succeededAt, isNull);
      expect(timing.isDue(now.add(Duration(minutes: minutes, milliseconds: -1)), const Duration(hours: 24)), isFalse);
      now = now.add(Duration(minutes: minutes));
      expect(timing.isDue(now, const Duration(hours: 24)), isTrue);
    }
    final restored = AutomaticCheckTiming()..restore(timing.toJson());
    expect(restored.failures, 4);
    restored.complete(now, success: true);
    expect(restored.isDue(now.add(const Duration(hours: 23)), const Duration(hours: 24)), isFalse);
    expect(restored.isDue(now.subtract(const Duration(minutes: 1)), const Duration(hours: 24)), isTrue);
    expect(restored.failures, 0);
  });
}
