import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/library/application/library_entry_destination.dart';

void main() {
  test('routes every supported shelf kind to its reader or player host', () {
    expect(libraryEntryDestination(ContentKind.novel), LibraryEntryDestination.reader);
    expect(libraryEntryDestination(ContentKind.manga), LibraryEntryDestination.reader);
    expect(libraryEntryDestination(ContentKind.audio), LibraryEntryDestination.audioPlayer);
    expect(libraryEntryDestination(ContentKind.video), LibraryEntryDestination.videoPlayer);
  });
}
