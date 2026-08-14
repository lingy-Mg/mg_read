import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';

void main() {
  group('DiagnosticValue', () {
    test('uses deterministic tagged encoding and round trips', () {
      final value = DiagnosticValueBuilder().buildAttributes(<String, Object?>{
        'stringValue': 'hello',
        'integerValue': 9223372036854775807,
        'nestedValue': <String, Object?>{'enabled': true, 'missing': null},
      });
      final wire = jsonDecode(jsonEncode(value.toWireValue()));
      final decoded = const DiagnosticValueCodec().decode(wire);

      expect(decoded, value);
      expect(value.values.keys, <String>[
        'integerValue',
        'nestedValue',
        'stringValue',
      ]);
    });

    test('represents limit breaches with a typed truncated node', () {
      final builder = DiagnosticValueBuilder(
        budget: const DiagnosticValueBudget(maxStringBytes: 4),
      );

      expect(
        builder.build('longer than four bytes'),
        isA<DiagnosticTruncatedValue>()
            .having((value) => value.reason, 'reason', 'stringByteLimit')
            .having((value) => value.originalCount, 'originalCount', 22),
      );
    });

    test('detects cycles without recursing indefinitely', () {
      final value = <Object?>[];
      value.add(value);

      final built = DiagnosticValueBuilder().build(value);

      expect(
        built,
        isA<DiagnosticListValue>().having(
          (list) => list.values.single,
          'cycle node',
          isA<DiagnosticTruncatedValue>().having(
            (node) => node.reason,
            'reason',
            'cycle',
          ),
        ),
      );
    });

    test('never invokes arbitrary toString or toJson', () {
      final value = _ExplosiveObject();

      expect(
        () => DiagnosticValueBuilder().build(value),
        throwsA(isA<DiagnosticValueBuildError>()),
      );
      expect(value.wasInvoked, isFalse);
    });

    test('rejects non-finite doubles and out-of-range int64', () {
      expect(
        () => DiagnosticValueBuilder().build(double.nan),
        throwsA(isA<DiagnosticValueBuildError>()),
      );
      expect(
        () => DiagnosticInt64Value('9223372036854775808'),
        throwsRangeError,
      );
    });
  });
}

final class _ExplosiveObject {
  bool wasInvoked = false;

  Object toJson() {
    wasInvoked = true;
    throw StateError('toJson must not run');
  }

  @override
  String toString() {
    wasInvoked = true;
    throw StateError('toString must not run');
  }
}
