import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/app/source_verification_command.dart';
import 'package:mg_read/features/plugins/application/source_verification.dart';

void main() {
  test('ignores ordinary app arguments and parses one source command', () {
    expect(parseSourceVerificationCommand(const <String>[]), isNull);

    final command = parseSourceVerificationCommand(const <String>['--source-check=org.mgread.fixture']);

    expect(command, isNotNull);
    expect(command!.pluginId, 'org.mgread.fixture');
    expect(command.all, isFalse);
  });

  test('parses all-sources mode and rejects ambiguous selection', () {
    final command = parseSourceVerificationCommand(const <String>['--source-check-all']);
    expect(command!.all, isTrue);

    expect(
      () => parseSourceVerificationCommand(const <String>['--source-check-all', '--source-check', 'org.mgread.fixture']),
      throwsA(isA<SourceVerificationRunException>()),
    );
  });

  test('keeps the selected source id without a report path', () {
    final command = parseSourceVerificationCommand(const <String>['--source-check', 'org.mgread.diyibanzhu-me']);

    expect(command!.pluginId, 'org.mgread.diyibanzhu-me');
    expect(command.all, isFalse);
  });
}
