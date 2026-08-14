import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/persistence/src/diagnostic_sha256.dart';

void main() {
  test('incremental SHA-256 matches standard vectors', () {
    expect(_digest(const <int>[]), _emptyDigest);
    expect(_digest(utf8.encode('abc')), _abcDigest);

    final chunked = DiagnosticSha256()
      ..add(utf8.encode('a'))
      ..add(utf8.encode('b'))
      ..add(utf8.encode('c'));
    expect(chunked.closeHex(), _abcDigest);
  });
}

String _digest(List<int> bytes) {
  final digest = DiagnosticSha256()..add(bytes);
  return digest.closeHex();
}

const String _emptyDigest =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
const String _abcDigest =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
