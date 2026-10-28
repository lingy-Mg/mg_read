part of 'discovery_page.dart';

/// Compact popularity shelf used by the preview discovery composition.
class DiscoveryPopularBooks extends StatelessWidget {
  const DiscoveryPopularBooks({required this.books, required this.onBookPressed, super.key});

  final List<DiscoveryBookViewData> books;
  final ValueChanged<DiscoveryBookViewData> onBookPressed;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      key: const Key('discovery-popular-books'),
      constraints: const BoxConstraints(minHeight: 120),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: books
            .take(5)
            .map((DiscoveryBookViewData book) => DiscoveryPopularBook(data: book, onPressed: () => onBookPressed(book)))
            .toList(growable: false),
      ),
    );
  }
}
