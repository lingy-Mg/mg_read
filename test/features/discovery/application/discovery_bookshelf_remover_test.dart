import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/features/discovery/application/bookshelf_membership.dart';
import 'package:mg_read/features/discovery/application/discovery_bookshelf_remover.dart';

void main() {
  test('removes the resolved shelf item and keeps the optimistic projection absent', () async {
    final container = _container();
    addTearDown(container.dispose);
    final membership = container.read(bookshelfMembershipProvider.notifier);
    await membership.reload();
    String? removedId;
    final remover = CoordinatedDiscoveryBookshelfRemover(membership: membership, removeBook: (bookId) async => removedId = bookId);

    await remover.remove(pluginId: 'source.test', title: '测试书');

    expect(removedId, 'book-1');
    expect(membership.contains(pluginId: 'source.test', title: '测试书'), isFalse);
  });

  test('restores the membership projection when durable removal fails', () async {
    final container = _container();
    addTearDown(container.dispose);
    final membership = container.read(bookshelfMembershipProvider.notifier);
    await membership.reload();
    final remover = CoordinatedDiscoveryBookshelfRemover(
      membership: membership,
      removeBook: (_) => Future<void>.error(StateError('remove failed')),
    );

    await expectLater(remover.remove(pluginId: 'source.test', title: '测试书'), throwsStateError);

    expect(membership.contains(pluginId: 'source.test', title: '测试书'), isTrue);
    expect(container.read(bookshelfMembershipProvider).entry(pluginId: 'source.test', title: '测试书')?.itemId, 'book-1');
  });
}

ProviderContainer _container() => ProviderContainer(
  overrides: [
    bookshelfMembershipLoaderProvider.overrideWithValue(
      const _MemoryMembershipLoader(<BookshelfMembershipEntry>[
        BookshelfMembershipEntry(itemId: 'book-1', pluginId: 'source.test', title: '测试书'),
      ]),
    ),
  ],
);

final class _MemoryMembershipLoader implements BookshelfMembershipLoader {
  const _MemoryMembershipLoader(this.entries);

  final List<BookshelfMembershipEntry> entries;

  @override
  Future<Iterable<BookshelfMembershipEntry>> load() async => entries;
}
