import 'dart:async';
import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/library/application/library_overview_loader.dart';
import 'package:mg_read/features/library/application/library_page_controller.dart';
import 'package:mg_read/features/library/application/library_page_state.dart';
import 'package:mg_read/features/library/domain/library_item_summary.dart';
import 'package:mg_read/features/library/domain/library_overview.dart';

void main() {
  test('latest request generation wins when refreshes overlap', () async {
    final _ControlledLibraryOverviewLoader loader =
        _ControlledLibraryOverviewLoader();
    final ProviderContainer container = ProviderContainer(
      overrides: [libraryOverviewLoaderProvider.overrideWithValue(loader)],
    );
    addTearDown(container.dispose);
    final ProviderSubscription<LibraryPageState> subscription = container
        .listen(
          libraryPageControllerProvider,
          (_, _) {},
          fireImmediately: true,
        );
    addTearDown(subscription.close);

    await _flush();
    loader.completeNext(_overview('initial'));
    await _flush();

    final LibraryPageController controller = container.read(
      libraryPageControllerProvider.notifier,
    );
    final Future<void> olderRefresh = controller.refresh();
    final Future<void> newerRefresh = controller.refresh();

    loader.completeAt(1, _overview('newer'));
    await _flush();
    loader.completeAt(0, _overview('older'));
    await Future.wait(<Future<void>>[olderRefresh, newerRefresh]);
    await _flush();

    final LibraryPageState state = container.read(
      libraryPageControllerProvider,
    );
    expect(state.status, LibraryPageStatus.content);
    expect(state.overview!.items.single.title, 'newer');
  });
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

LibraryOverview _overview(String title) {
  return LibraryOverview(
    items: <LibraryItemSummary>[
      LibraryItemSummary(id: 'book-$title', title: title),
    ],
  );
}

final class _ControlledLibraryOverviewLoader implements LibraryOverviewLoader {
  final Queue<Completer<LibraryOverview>> _pending =
      Queue<Completer<LibraryOverview>>();

  @override
  Future<LibraryOverview> load() {
    final Completer<LibraryOverview> completer = Completer<LibraryOverview>();
    _pending.add(completer);
    return completer.future;
  }

  void completeNext(LibraryOverview overview) {
    _pending.removeFirst().complete(overview);
  }

  void completeAt(int index, LibraryOverview overview) {
    _pending.elementAt(index).complete(overview);
  }
}
