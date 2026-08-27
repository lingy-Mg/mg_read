import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/features/reader/application/reader_launch_request.dart';

/// Resolves a shelf item's stable identifier into a host-owned reader session.
abstract interface class LibraryReaderLauncher {
  /// Builds the data source and state store required by the reader plugin.
  Future<ReaderLaunchRequest> launch(String libraryItemId);
}

/// Composition port. The app bootstrap supplies the persistent implementation.
final libraryReaderLauncherProvider = Provider<LibraryReaderLauncher>(
  (Ref ref) => const _UnavailableLibraryReaderLauncher(),
);

final class _UnavailableLibraryReaderLauncher implements LibraryReaderLauncher {
  const _UnavailableLibraryReaderLauncher();

  @override
  Future<ReaderLaunchRequest> launch(String libraryItemId) =>
      Future<ReaderLaunchRequest>.error(
        StateError('Persistent bookshelf reading is unavailable.'),
      );
}
