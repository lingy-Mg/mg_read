import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/features/discovery/application/bookshelf_membership.dart';

void main() {
  test('loads the shelf once and answers same-source title checks in O(1)', () async {
    final loader = _FakeMembershipLoader(<BookshelfMembershipEntry>[
      const BookshelfMembershipEntry(itemId: 'book-1', pluginId: 'source.a', title: '  诡秘   之主  '),
    ]);
    final container = ProviderContainer(overrides: [bookshelfMembershipLoaderProvider.overrideWithValue(loader)]);
    addTearDown(container.dispose);

    final controller = container.read(bookshelfMembershipProvider.notifier);
    await controller.reload();

    expect(container.read(bookshelfMembershipProvider).contains(pluginId: 'source.a', title: '诡秘 之主'), isTrue);
    expect(container.read(bookshelfMembershipProvider).contains(pluginId: 'source.b', title: '诡秘 之主'), isFalse);
    expect(loader.loadCount, 1);

    expect(container.read(bookshelfMembershipProvider).entry(pluginId: 'source.a', title: '诡秘 之主')?.itemId, 'book-1');

    controller.markAdded(itemId: 'book-2', pluginId: 'source.a', title: '新书');
    expect(container.read(bookshelfMembershipProvider).contains(pluginId: 'source.a', title: '新书'), isTrue);

    final entry = container.read(bookshelfMembershipProvider).entry(pluginId: 'source.a', title: '新书')!;
    controller.markRemoved(entry);
    expect(container.read(bookshelfMembershipProvider).contains(pluginId: 'source.a', title: '新书'), isFalse);

    controller.markAdded(itemId: entry.itemId, pluginId: entry.pluginId, title: entry.title);
    expect(container.read(bookshelfMembershipProvider).contains(pluginId: 'source.a', title: '新书'), isTrue);
  });
}

final class _FakeMembershipLoader implements BookshelfMembershipLoader {
  _FakeMembershipLoader(this.entries);

  final List<BookshelfMembershipEntry> entries;
  int loadCount = 0;

  @override
  Future<Iterable<BookshelfMembershipEntry>> load() async {
    loadCount++;
    return entries;
  }
}
