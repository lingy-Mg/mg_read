// Streaming plain-text import. The parser owns only its staging output and keeps
// at most one bounded line segment plus one decoder chunk in memory.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'encoding/gb18030_index.dart';
import 'encoding/gb18030_ranges.dart';
import 'local_document_models.dart';
import 'local_document_disk_space.dart';

final class TxtLocalDocumentParser implements LocalDocumentParser {
  const TxtLocalDocumentParser();

  static const _maxTextUnits = 32 * 1024;
  static const _maxLineForHeading = 4096;

  @override
  Future<ParsedLocalDocument> parse({
    required File source,
    required Directory output,
    LocalDocumentParseOptions options = const LocalDocumentParseOptions(),
    LocalDocumentCancellation? cancellation,
    LocalDocumentProgress? onProgress,
  }) async {
    cancellation?.check();
    final size = await source.length();
    if (size > localDocumentMaxFileBytes) {
      throw const LocalDocumentException('file_too_large');
    }
    if (!await output.exists()) await output.create(recursive: true);
    final available = await availableLocalDocumentBytes(output);
    if (available != null && available < size * 3 + 16 * 1024 * 1024) throw const LocalDocumentException('disk_full');
    final encoding = await _resolveEncoding(source, size, options, cancellation, onProgress);
    final rule = _ChapterRule.parse(options.chapterRule);
    final parser = _TxtWriter(output, source.uri.pathSegments.isEmpty ? 'Untitled' : _basename(source.path), rule, cancellation);
    try {
      await parser.consume(_decodedChunks(source, encoding, options.allowMalformed, cancellation, onProgress, size));
      return await parser.finish(encoding);
    } on LocalDocumentException {
      await parser.abort();
      rethrow;
    } on FormatException catch (error) {
      await parser.abort();
      throw LocalDocumentException('malformed_text', error.message);
    } on FileSystemException catch (error) {
      await parser.abort();
      if ({28, 39, 112}.contains(error.osError?.errorCode)) throw const LocalDocumentException('disk_full');
      throw LocalDocumentException('read_failed', error.message);
    }
  }

  static String _basename(String path) {
    final name = path.split(RegExp(r'[/\\]')).last;
    return name.replaceFirst(RegExp(r'\.[^.]*$'), '').trim().isEmpty ? 'Untitled' : name.replaceFirst(RegExp(r'\.[^.]*$'), '').trim();
  }

  static Future<String> _resolveEncoding(
    File source,
    int size,
    LocalDocumentParseOptions options,
    LocalDocumentCancellation? cancellation,
    LocalDocumentProgress? onProgress,
  ) async {
    final requested = options.encoding?.trim().toLowerCase().replaceAll('_', '-');
    if (requested != null && requested.isNotEmpty) {
      if (const {'utf-8', 'utf8'}.contains(requested)) return 'utf-8';
      if (const {'utf-16le', 'utf16le'}.contains(requested)) return 'utf-16le';
      if (const {'utf-16be', 'utf16be'}.contains(requested)) return 'utf-16be';
      if (const {'gb18030', 'gb-18030', 'gbk', 'gb2312'}.contains(requested)) return 'gb18030';
      throw LocalDocumentException('unsupported_encoding', options.encoding);
    }
    final prefix = await source.openRead(0, math.min(size, 4)).fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    if (prefix.length >= 4 &&
        ((prefix[0] == 0xff && prefix[1] == 0xfe && prefix[2] == 0 && prefix[3] == 0) ||
            (prefix[0] == 0 && prefix[1] == 0 && prefix[2] == 0xfe && prefix[3] == 0xff))) {
      throw const LocalDocumentException('unsupported_encoding', 'UTF-32');
    }
    if (prefix.length >= 3 && prefix[0] == 0xef && prefix[1] == 0xbb && prefix[2] == 0xbf) return 'utf-8';
    if (prefix.length >= 2 && prefix[0] == 0xff && prefix[1] == 0xfe) return 'utf-16le';
    if (prefix.length >= 2 && prefix[0] == 0xfe && prefix[1] == 0xff) return 'utf-16be';
    cancellation?.check();
    if (options.allowMalformed) return 'utf-8';
    final sample = await source.openRead(0, math.min(size, 4096)).fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    if (sample.length >= 16) {
      var evenZeros = 0, oddZeros = 0, pairs = sample.length ~/ 2;
      for (var i = 0; i < pairs * 2; i += 2) {
        if (sample[i] == 0) evenZeros++;
        if (sample[i + 1] == 0) oddZeros++;
      }
      if (oddZeros / pairs > 0.6 && evenZeros / pairs < 0.1) return 'utf-16le';
      if (evenZeros / pairs > 0.6 && oddZeros / pairs < 0.1) return 'utf-16be';
    }
    // UTF-8 is accepted when valid. A failed probe is retried as GB18030 only
    // when the sampled text has clear multibyte CJK evidence; otherwise ask.
    try {
      await utf8.decoder.bind(source.openRead().transform(_ProgressBytes(cancellation, onProgress, 'detect', size))).drain<void>();
      return 'utf-8';
    } on FormatException {
      try {
        final gbSample = await source.openRead(0, math.min(size, 8192)).fold<List<int>>(<int>[], (a, b) => a..addAll(b));
        String? decoded;
        for (var trim = 0; trim <= 3 && trim <= gbSample.length; trim++) {
          try {
            decoded = _decodeGbBytes(gbSample.sublist(0, gbSample.length - trim), false).text;
            break;
          } on FormatException {
            // A sample boundary can split a valid multibyte sequence.
          }
        }
        if (decoded == null) throw const FormatException('Invalid GB18030 sample');
        final cjk = RegExp(r'[\u3400-\u9fff]').allMatches(decoded).length;
        if (cjk >= 2) return 'gb18030';
      } on FormatException {
        // A failed strict GB18030 sample is not enough evidence for a charset.
      }
      throw const LocalDocumentException('encoding_required');
    }
  }

  static Stream<String> _decodedChunks(
    File source,
    String encoding,
    bool allowMalformed,
    LocalDocumentCancellation? cancellation,
    LocalDocumentProgress? onProgress,
    int total,
  ) async* {
    final stream = source.openRead();
    if (encoding == 'utf-8') {
      var first = true;
      await for (final text in Utf8Decoder(
        allowMalformed: allowMalformed,
      ).bind(stream.transform(_ProgressBytes(cancellation, onProgress, 'parse', total)))) {
        cancellation?.check();
        if (text.isEmpty) continue;
        yield first && text.startsWith('\ufeff') ? text.substring(1) : text;
        first = false;
      }
      return;
    }
    if (encoding.startsWith('utf-16')) {
      final little = encoding == 'utf-16le';
      var firstUnit = true;
      var pendingByte = -1;
      var pendingHigh = -1;
      await for (final bytes in stream.transform(_ProgressBytes(cancellation, onProgress, 'parse', total))) {
        final units = <int>[];
        var i = 0;
        if (pendingByte >= 0 && bytes.isNotEmpty) {
          units.add(little ? pendingByte | (bytes[0] << 8) : (pendingByte << 8) | bytes[0]);
          i = 1;
          pendingByte = -1;
        }
        for (; i + 1 < bytes.length; i += 2) {
          units.add(little ? bytes[i] | (bytes[i + 1] << 8) : (bytes[i] << 8) | bytes[i + 1]);
        }
        if (i < bytes.length) pendingByte = bytes[i];
        final out = <int>[];
        for (final unit in units) {
          if (firstUnit) {
            firstUnit = false;
            if (unit == 0xfeff) continue;
          }
          if (pendingHigh >= 0) {
            if (unit >= 0xdc00 && unit <= 0xdfff) {
              out
                ..add(pendingHigh)
                ..add(unit);
              pendingHigh = -1;
              continue;
            }
            if (!allowMalformed) throw const FormatException('Unpaired UTF-16 surrogate');
            out.add(0xfffd);
            pendingHigh = -1;
          }
          if (unit >= 0xd800 && unit <= 0xdbff) {
            pendingHigh = unit;
          } else if (unit >= 0xdc00 && unit <= 0xdfff) {
            if (!allowMalformed) throw const FormatException('Unpaired UTF-16 surrogate');
            out.add(0xfffd);
          } else {
            out.add(unit);
          }
        }
        if (out.isNotEmpty) yield String.fromCharCodes(out);
      }
      if (pendingByte >= 0 || pendingHigh >= 0) {
        if (!allowMalformed) throw const FormatException('Truncated UTF-16 code unit');
        yield '\ufffd';
      }
      return;
    }
    var decoder = _Gb18030Decoder(allowMalformed);
    await for (final bytes in stream.transform(_ProgressBytes(cancellation, onProgress, 'parse', total))) {
      final text = decoder.add(bytes);
      if (text.isNotEmpty) yield text;
    }
    final tail = decoder.close();
    if (tail.isNotEmpty) yield tail;
  }

  static _GbResult _decodeGbBytes(List<int> bytes, bool allowMalformed) {
    final decoder = _Gb18030Decoder(allowMalformed);
    final text = decoder.add(bytes) + decoder.close();
    return _GbResult(text);
  }
}

final class _GbResult {
  const _GbResult(this.text);
  final String text;
}

final class _ProgressBytes extends StreamTransformerBase<List<int>, List<int>> {
  const _ProgressBytes(this.cancellation, this.progress, this.stage, this.total);
  final LocalDocumentCancellation? cancellation;
  final LocalDocumentProgress? progress;
  final String stage;
  final int total;
  @override
  Stream<List<int>> bind(Stream<List<int>> stream) async* {
    var completed = 0;
    await for (final chunk in stream) {
      cancellation?.check();
      completed += chunk.length;
      progress?.call(stage, math.min(completed, total), total);
      yield chunk;
    }
  }
}

final class _Gb18030Decoder {
  _Gb18030Decoder(this.allowMalformed);
  final bool allowMalformed;
  final List<int> _pending = [];
  final StringBuffer _out = StringBuffer();

  String add(List<int> bytes) {
    for (final b in bytes) {
      _pending.add(b);
      _drain(finalInput: false);
    }
    final text = _out.toString();
    _out.clear();
    return text;
  }

  String close() {
    _drain(finalInput: true);
    final text = _out.toString();
    _out.clear();
    return text;
  }

  void _invalid(int consume) {
    if (!allowMalformed) throw const FormatException('Malformed GB18030 sequence');
    _out.write('\ufffd');
    _pending.removeRange(0, consume.clamp(1, _pending.length));
  }

  void _drain({required bool finalInput}) {
    while (_pending.isNotEmpty) {
      final a = _pending[0];
      if (a <= 0x7f) {
        _out.writeCharCode(a);
        _pending.removeAt(0);
        continue;
      }
      if (a < 0x81 || a > 0xfe) {
        _invalid(1);
        continue;
      }
      if (_pending.length < 2) {
        if (finalInput) _invalid(1);
        return;
      }
      final b = _pending[1];
      if (b >= 0x30 && b <= 0x39) {
        if (_pending.length < 4) {
          if (finalInput) _invalid(1);
          return;
        }
        final c = _pending[2], d = _pending[3];
        if (c < 0x81 || c > 0xfe || d < 0x30 || d > 0x39) {
          _invalid(1);
          continue;
        }
        final pointer = (((a - 0x81) * 10 + b - 0x30) * 126 + c - 0x81) * 10 + d - 0x30;
        final cp = _gbRangeCodePoint(pointer);
        if (cp == null) {
          _invalid(4);
          continue;
        }
        _writeCodePoint(cp);
        _pending.removeRange(0, 4);
        continue;
      }
      if (b < 0x40 || b > 0xfe || b == 0x7f) {
        _invalid(1);
        continue;
      }
      final pointer = (a - 0x81) * 190 + b - (b < 0x7f ? 0x40 : 0x41);
      final cp = pointer < gb18030Index.length ? gb18030Index[pointer] : 0xffff;
      if (cp == 0xffff) {
        _invalid(2);
        continue;
      }
      _writeCodePoint(cp);
      _pending.removeRange(0, 2);
    }
  }

  static int? _gbRangeCodePoint(int pointer) {
    if ((pointer > 39419 && pointer < 189000) || pointer > 1237575) return null;
    if (pointer == 7457) return 0xe7c7;
    var low = 0, high = gb18030Ranges.length - 1, found = -1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      if (gb18030Ranges[mid].$1 <= pointer) {
        found = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return found < 0 ? null : gb18030Ranges[found].$2 + pointer - gb18030Ranges[found].$1;
  }

  void _writeCodePoint(int cp) {
    if (cp <= 0xffff) {
      _out.writeCharCode(cp);
    } else {
      final v = cp - 0x10000;
      _out
        ..writeCharCode(0xd800 + (v >> 10))
        ..writeCharCode(0xdc00 + (v & 0x3ff));
    }
  }
}

final class _ChapterRule {
  _ChapterRule(this.name, this.expression);
  final String name;
  final RegExp? expression;
  static _ChapterRule parse(String value) {
    if (const {'auto', 'chinese', 'english', 'none'}.contains(value)) return _ChapterRule(value, null);
    if (value.startsWith('regex:')) {
      final pattern = value.substring(6);
      if (pattern.isEmpty ||
          pattern.length > 128 ||
          pattern.contains('(?') ||
          RegExp(r'\\[1-9]').hasMatch(pattern) ||
          RegExp(r'\([^)]*[+*{][^)]*\)[+*{]').hasMatch(pattern)) {
        throw const LocalDocumentException('invalid_chapter_rule');
      }
      try {
        return _ChapterRule(value, RegExp(pattern, caseSensitive: false));
      } on FormatException {
        throw const LocalDocumentException('invalid_chapter_rule');
      }
    }
    throw const LocalDocumentException('invalid_chapter_rule');
  }

  bool isHeading(String line) {
    if (name == 'none' || line.length > TxtLocalDocumentParser._maxLineForHeading) return false;
    final text = line.trim();
    if (text.isEmpty) return false;
    if (expression != null) return expression!.hasMatch(text);
    final chinese = RegExp(r'^(第\s*[零〇一二三四五六七八九十百千万两\d]+\s*[章节卷回集部篇].{0,80})$');
    final english = RegExp(r'^(chapter|book|part|volume)\s+([\divxlcdm]+)(\b|\s|[:：.、-]).{0,80}$', caseSensitive: false);
    if (name == 'chinese') return chinese.hasMatch(text);
    if (name == 'english') return english.hasMatch(text);
    return chinese.hasMatch(text) || english.hasMatch(text);
  }
}

final class _TxtWriter {
  _TxtWriter(this.output, this.title, this.rule, this.cancellation);
  final Directory output;
  final String title;
  final _ChapterRule rule;
  final LocalDocumentCancellation? cancellation;
  final StringBuffer _line = StringBuffer();
  final List<LocalDocumentChapter> _chapters = [];
  final List<String> _logicalStarts = [];
  IOSink? _sink;
  int _chapterBlocks = 0, _chapterWords = 0, _chapterStart = 0, _pageTextUnits = 0;
  int _offset = 0;
  bool _pendingCr = false, _lineOverflowed = false;
  String _chapterTitle = '';

  Future<void> consume(Stream<String> chunks) async {
    await for (final chunk in chunks) {
      cancellation?.check();
      for (final rune in chunk.runes) {
        final s = String.fromCharCode(rune);
        if (_pendingCr) {
          await _acceptLineEnd();
          _pendingCr = false;
          if (s == '\n') continue;
        }
        if (s == '\r') {
          _pendingCr = true;
          continue;
        }
        if (s == '\n') {
          await _acceptLineEnd();
          continue;
        }
        if (_line.length + s.length >= TxtLocalDocumentParser._maxTextUnits) {
          _lineOverflowed = true;
          await _flushLineSegment(terminated: false);
        }
        _line.write(s);
      }
    }
    if (_pendingCr) {
      await _acceptLineEnd();
      _pendingCr = false;
    }
    if (_line.isNotEmpty) await _flushLineSegment(terminated: false, endLine: true);
  }

  Future<void> _acceptLineEnd() async {
    await _flushLineSegment(terminated: true, endLine: true);
  }

  Future<void> _flushLineSegment({required bool terminated, bool endLine = false}) async {
    final text = _line.toString();
    _line.clear();
    final start = _offset;
    final fullLine = !_lineOverflowed && text.length <= TxtLocalDocumentParser._maxLineForHeading;
    final heading = terminated && fullLine && rule.isHeading(text);
    if (heading) await _openChapter(text.trim(), start);
    if (text.isNotEmpty || terminated) {
      final body = terminated ? '$text\n' : text;
      await _writeBlock(heading ? 'heading' : 'paragraph', body, start);
      _offset += body.length;
    }
    if (endLine) _lineOverflowed = false;
  }

  Future<void> _openChapter(String heading, int start) async {
    await _closeChapter();
    if (_chapters.length >= localDocumentMaxEntries) throw const LocalDocumentException('too_many_chapters');
    _chapterTitle = heading;
    _chapterStart = start;
    await _startChapter(start);
  }

  Future<void> _startChapter(int start, {bool continuation = false}) async {
    final index = _chapters.length;
    if (!continuation) _logicalStarts.add('c${(index + 1).toString().padLeft(5, '0')}');
    final file = 'chapters/chapter-${(index + 1).toString().padLeft(5, '0')}.json';
    final target = File('${output.path}${Platform.pathSeparator}${file.replaceAll('/', Platform.pathSeparator)}');
    await target.parent.create(recursive: true);
    _sink = target.openWrite();
    _sink!.write(
      '{"chapterId":"c${(index + 1).toString().padLeft(5, '0')}","title":${jsonEncode(_chapterTitle.isEmpty ? title : _chapterTitle)},"blocks":[',
    );
    _chapterBlocks = 0;
    _chapterWords = 0;
    _pageTextUnits = 0;
    _chapterStart = start;
  }

  Future<void> _writeBlock(String type, String text, int start) async {
    if (_sink == null) await _startChapter(start);
    if (_chapterBlocks > 0 && _pageTextUnits + text.length > TxtLocalDocumentParser._maxTextUnits) {
      await _closeChapter();
      if (_chapters.length >= localDocumentMaxEntries) {
        throw const LocalDocumentException('too_many_chapters');
      }
      await _startChapter(start, continuation: true);
    }
    if (_chapterBlocks > 0) _sink!.write(',');
    final id = 'p$start';
    _sink!.write(jsonEncode({'id': id, 'type': type, 'text': text, 'sourceOffset': start}));
    _chapterBlocks++;
    _pageTextUnits += text.length;
    _chapterWords += _countWords(text);
  }

  Future<void> _closeChapter() async {
    final sink = _sink;
    if (sink == null) return;
    sink.write(']}');
    await sink.flush();
    await sink.close();
    _sink = null;
    final index = _chapters.length;
    _chapters.add(
      LocalDocumentChapter(
        id: 'c${(index + 1).toString().padLeft(5, '0')}',
        title: _chapterTitle.isEmpty ? title : _chapterTitle,
        index: index,
        contentFile: 'chapters/chapter-${(index + 1).toString().padLeft(5, '0')}.json',
        wordCount: _chapterWords,
        startOffset: _chapterStart,
      ),
    );
  }

  Future<ParsedLocalDocument> finish(String encoding) async {
    cancellation?.check();
    if (_sink == null && _chapters.isEmpty) await _startChapter(0);
    await _closeChapter();
    return ParsedLocalDocument(
      format: LocalDocumentFormat.txt,
      title: title,
      encoding: encoding,
      chapters: List.unmodifiable(_chapters),
      attributes: {'logicalChapterStarts': _logicalStarts},
      navigation: [
        for (final chapter in _chapters)
          if (_logicalStarts.contains(chapter.id)) LocalDocumentNavigation(label: chapter.title, chapterId: chapter.id),
      ],
    );
  }

  Future<void> abort() async {
    final sink = _sink;
    _sink = null;
    if (sink == null) return;
    try {
      await sink.close();
    } on FileSystemException {
      // Preserve the original parse/write failure while releasing the handle.
    }
  }

  static int _countWords(String text) {
    var count = 0, latin = false;
    for (final rune in text.runes) {
      final cjk = (rune >= 0x3400 && rune <= 0x9fff) || (rune >= 0xf900 && rune <= 0xfaff);
      final word =
          (rune >= 0x30 && rune <= 0x39) ||
          (rune >= 0x41 && rune <= 0x5a) ||
          (rune >= 0x61 && rune <= 0x7a) ||
          rune >= 0x80 && !cjk && !RegExp(r'\s').hasMatch(String.fromCharCode(rune));
      if (cjk) {
        count++;
        latin = false;
      } else if (word) {
        if (!latin) count++;
        latin = true;
      } else {
        latin = false;
      }
    }
    return count;
  }
}
