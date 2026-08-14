import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';

void main() {
  group('DiagnosticPrivacyPolicy', () {
    final policy = DiagnosticPrivacyPolicy();

    test('removes secret values recursively', () {
      final definition = DiagnosticEventDefinition.instant(
        name: 'test.privacy',
        component: 'test.privacy',
        summary: 'Privacy test.',
        fields: <String, DiagnosticFieldDefinition>{
          'metadata': const DiagnosticFieldDefinition(
            type: DiagnosticFieldType.object,
          ),
        },
      );
      final sanitized = policy.sanitizeAttributes(
        definition: definition,
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'metadata': DiagnosticObjectValue(<String, DiagnosticValue>{
            'authorization': DiagnosticValue.string('Bearer canary-secret'),
            'safeCount': DiagnosticValue.int64(3),
          }),
        }),
      );
      final metadata = sanitized.values['metadata']! as DiagnosticObjectValue;

      expect(metadata.values['authorization'], isA<DiagnosticRedactedValue>());
      expect(metadata.values['safeCount'], DiagnosticValue.int64(3));
      expect(
        sanitized.toWireValue().toString(),
        isNot(contains('canary-secret')),
      );
    });

    test('projects URL query keys without values or user info', () {
      final projected = policy.projectUrl(
        Uri.parse(
          'https://user:password@example.com/books/42?token=canary&lang=zh',
        ),
        routeTemplate: '/books/{bookId}',
      );
      final wire = projected.toWireValue().toString();

      expect(wire, contains('https://example.com'));
      expect(wire, contains('/books/{bookId}'));
      expect(wire, contains('token'));
      expect(wire, isNot(contains('canary')));
      expect(wire, isNot(contains('password')));
    });

    test('blocks credential header values and unknown header values', () {
      final headers = policy.sanitizeHeaders(<String, List<String>>{
        'Authorization': <String>['Bearer canary-secret'],
        'Content-Type': <String>['application/json'],
        'X-Debug-Text': <String>['private text'],
      });
      final wire = headers.toWireValue().toString();

      expect(wire, contains('application/json'));
      expect(wire, isNot(contains('canary-secret')));
      expect(wire, isNot(contains('private text')));
    });

    test('stack fingerprint is stable and does not expose source paths', () {
      final first = policy.stackFingerprint(
        StackTrace.fromString(
          r'#0 C:\Users\person\secret\source.dart:42:7 token=canary',
        ),
      );
      final second = policy.stackFingerprint(
        StackTrace.fromString(
          r'#0 C:\Users\person\secret\source.dart:42:7 token=canary',
        ),
      );

      expect(first, second);
      expect(first, matches(RegExp(r'^[a-f0-9]{16}$')));
      expect(first, isNot(contains('canary')));
    });
  });
}
