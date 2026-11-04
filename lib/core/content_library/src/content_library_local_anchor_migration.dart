/// Bounded semantic relocation across parser rules and original revisions.
/// Absolute TXT offsets are exact only for the same bytes and decoder. Changed
/// text uses a contextual quote; unmatched locations retain a rollback snapshot.
part of 'content_library.dart';

typedef _MappedLocalAnchor = ({String chapterId, String paragraphId, int offset, int index, bool exact});

Iterable<Map> _flattenLocalBlocks(Object? value) sync* {
  if (value is! List) return;
  for (final block in value.whereType<Map>()) {
    yield block;
    yield* _flattenLocalBlocks(block['children']);
  }
}

String _localBlockText(Map block) {
  final spans = block['spans'];
  return spans is List && spans.isNotEmpty
      ? spans.whereType<Map>().map((span) => span['text'] as String? ?? '').join()
      : block['text'] as String? ?? '';
}

Future<_MappedLocalAnchor> _mapLocalAnchor(
  Directory stage,
  ParsedLocalDocument document,
  LocalDocumentReadingSession? old,
  String chapterId,
  String paragraphId,
  int offset,
  double fraction,
  String excerpt, {
  LocalDocumentReadingSession? targetSession,
  String? newHash,
  LocalDocumentCancellation? cancel,
}) async {
  cancel?.check();
  final sameOriginal = old != null && old.rawSha256 == newHash && old._document.encoding == document.encoding;
  String? oldText;
  if (old != null && old.chapterById(chapterId) != null) {
    final previous = await old.readChapter(chapterId);
    final block = _flattenLocalBlocks(previous['blocks']).where((block) => block['id'] == paragraphId).firstOrNull;
    if (block != null) oldText = _localBlockText(block);
  }
  var quote = excerpt;
  var quoteOffset = 0;
  if (oldText != null && oldText.isNotEmpty) {
    final clamped = offset.clamp(0, oldText.length);
    final from = (clamped - 24).clamp(0, oldText.length);
    quote = oldText.substring(from, (clamped + 48).clamp(from, oldText.length));
    quoteOffset = clamped - from;
  }
  final global = paragraphId.startsWith('p') ? int.tryParse(paragraphId.substring(1)) : null;
  LocalDocumentChapter? target = document.chapters.where((chapter) => chapter.id == chapterId).firstOrNull;
  if (document.format == LocalDocumentFormat.txt && global != null) {
    target = document.chapters.where((chapter) => chapter.startOffset <= global + offset).lastOrNull ?? document.chapters.first;
  }
  target ??= document.chapters[(fraction * document.chapters.length).floor().clamp(0, document.chapters.length - 1)];
  Future<List<Map>> load(LocalDocumentChapter chapter) async {
    cancel?.check();
    final body = targetSession == null ? await _readStagedJson(stage, chapter.contentFile) : await targetSession.readChapter(chapter.id);
    return _flattenLocalBlocks(body['blocks']).toList(growable: false);
  }

  _MappedLocalAnchor location(LocalDocumentChapter chapter, Map block, int character, bool exact) => (
    chapterId: chapter.id,
    paragraphId: block['id']! as String,
    offset: character.clamp(0, _localBlockText(block).length),
    index: chapter.index,
    exact: exact,
  );
  final initial = await load(target);
  final stable = initial.where((block) => block['id'] == paragraphId).firstOrNull;
  if (stable != null && (sameOriginal || old == null || oldText == _localBlockText(stable))) return location(target, stable, offset, true);
  if (sameOriginal && global != null && document.format == LocalDocumentFormat.txt && initial.isNotEmpty) {
    final absolute = global + offset;
    final block = initial.where((block) => (block['sourceOffset'] as int? ?? 0) <= absolute).lastOrNull ?? initial.first;
    return location(target, block, absolute - (block['sourceOffset'] as int? ?? 0), true);
  }
  if (quote.trim().isNotEmpty) {
    final visited = <String>{};
    // Search close to the old logical chapter first. Keep only one chapter's
    // content in memory and observe cancellation between every bounded read.
    final candidates = <LocalDocumentChapter>[
      target,
      ...document.chapters.skip((target.index - 4).clamp(0, document.chapters.length)).take(9),
      ...document.chapters,
    ];
    for (final chapter in candidates) {
      if (!visited.add(chapter.id)) continue;
      final blocks = chapter.id == target.id ? initial : await load(chapter);
      for (final block in blocks) {
        final found = _localBlockText(block).indexOf(quote);
        if (found >= 0) return location(chapter, block, found + quoteOffset, quote.length >= 12 || block['id'] == paragraphId);
      }
    }
  }
  if (stable != null) return location(target, stable, offset, false);
  if (initial.isNotEmpty) return location(target, initial.first, 0, false);
  return (chapterId: target.id, paragraphId: '${target.id}:empty', offset: 0, index: target.index, exact: false);
}
