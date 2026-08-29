import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/features/reader/data/bounded_reader_session_cache.dart';

void main() {
  test('evicts the least recently used entry at the entry limit', () {
    final cache = BoundedReaderSessionCache<String, String>(maxEntries: 3);

    cache['one'] = '1';
    cache['two'] = '2';
    cache['three'] = '3';
    expect(cache['one'], '1');
    cache['four'] = '4';

    expect(cache['two'], isNull);
    expect(cache['one'], '1');
    expect(cache.length, 3);
  });

  test('enforces weight and does not retain an oversized value', () {
    final cache = BoundedReaderSessionCache<String, String>(
      maxEntries: 10,
      maxWeight: 8,
      weightOf: (String _, String value) => value.length * 2,
    );

    cache['one'] = 'aa';
    cache['two'] = 'bb';
    cache['three'] = 'c';
    expect(cache['one'], isNull);
    expect(cache.weight, 6);

    cache['oversized'] = '12345';
    expect(cache['oversized'], isNull);
    expect(cache.weight, 6);
  });
}
