part of 'document_reader_view.dart';

/// Rendering primitives split from the reader state owner to keep the view
/// controller focused on navigation, persistence, and lifecycle.
extension _DocumentReaderRendering on _DocumentReaderViewState {
  Widget _renderBlock(ReaderDocumentBlock block) {
    final key = _blockKeys.putIfAbsent(block.id, GlobalKey.new);
    for (final anchor in <String?>[block.anchor, ...block.anchors]) {
      if (anchor != null && anchor.isNotEmpty) {
        _blockKeys.putIfAbsent(anchor, () => key);
      }
    }
    return KeyedSubtree(key: key, child: _renderBlockContent(block));
  }

  Widget _renderBlockContent(ReaderDocumentBlock block) {
    final double fontSize = _preferences.fontSize;
    final style = block.style;
    final bookFontSize = _cssFontSize(
      style['font-size'] ?? style['fontSize'],
      fontSize,
    );
    final TextStyle textStyle = TextStyle(
      color: _useBookStyles
          ? _cssColor(style['color']) ?? _foreground
          : _foreground,
      fontSize: _useBookStyles ? bookFontSize : fontSize,
      height: _useBookStyles
          ? _cssLineHeight(style['line-height'], _preferences.lineHeight)
          : _preferences.lineHeight,
      letterSpacing: _preferences.letterSpacing,
      fontWeight: _cssFontWeight(style['font-weight'] ?? style['fontWeight']),
    );
    final double extraIndent = _cssIndent(style['margin-left'], fontSize);
    switch (block.type) {
      case 'image':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: _image(block),
        );
      case 'rule':
        return const Divider(height: 28);
      case 'heading':
        return Padding(
          padding: const EdgeInsets.only(top: 18, bottom: 12),
          child: _rich(
            block,
            textStyle.copyWith(
              fontSize: (_useBookStyles ? bookFontSize : fontSize) + 3,
              fontWeight: FontWeight.bold,
            ),
          ),
        );
      case 'quote':
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.only(left: 12),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: _foreground.withValues(alpha: .35),
                width: 3,
              ),
            ),
          ),
          child: _rich(
            block,
            textStyle.copyWith(color: _foreground.withValues(alpha: .8)),
          ),
        );
      case 'pre':
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.all(10),
          color: _foreground.withValues(alpha: .06),
          child: SelectableText(
            _blockText(block),
            style: textStyle.copyWith(fontFamily: 'monospace', height: 1.5),
          ),
        );
      case 'listItem':
        final depth = (style['depth'] as num?)?.toDouble() ?? 0;
        final ordered = style['ordered'] == true;
        final listIndex = (style['listIndex'] as num?)?.toInt() ?? 1;
        return Padding(
          padding: EdgeInsets.only(
            left: (16.0 + depth.clamp(0, 8) * 16 + extraIndent).clamp(0, 256),
            bottom: _preferences.paragraphSpacing,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(ordered ? '$listIndex.  ' : '•  ', style: textStyle),
              Expanded(child: _rich(block, textStyle)),
            ],
          ),
        );
      case 'table':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: block.children.map(_renderBlock).toList(),
          ),
        );
      case 'row':
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: block.children
              .map((child) => Expanded(child: _renderBlock(child)))
              .toList(),
        );
      case 'cell':
        return Container(
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            border: Border.all(color: _foreground.withValues(alpha: .15)),
          ),
          child: _rich(block, textStyle),
        );
      default:
        return Padding(
          padding: EdgeInsets.only(
            left: extraIndent,
            bottom: _preferences.paragraphSpacing,
          ),
          child: _rich(block, textStyle),
        );
    }
  }

  Widget _rich(ReaderDocumentBlock block, TextStyle base) {
    final align = _cssTextAlign(block.style['text-align']);
    if (block.spans.isEmpty) {
      return SelectableText(block.text, style: base, textAlign: align);
    }
    return SelectableText.rich(
      TextSpan(
        children: block.spans.asMap().entries.map((entry) {
          final int spanIndex = entry.key;
          final span = entry.value;
          var style = base;
          if (span.bold) style = style.copyWith(fontWeight: FontWeight.bold);
          if (span.italic) style = style.copyWith(fontStyle: FontStyle.italic);
          if (span.underline) {
            style = style.copyWith(decoration: TextDecoration.underline);
          }
          if (span.superscript || span.subscript) {
            style = style.copyWith(fontSize: base.fontSize! * .75);
          }
          if (span.href != null) {
            style = style.copyWith(
              color: Colors.blue,
              decoration: TextDecoration.underline,
            );
          }
          return TextSpan(
            text: span.text,
            style: style,
            recognizer: span.href == null
                ? null
                : _linkRecognizers
                      .putIfAbsent(
                        block.id,
                        () => <int, TapGestureRecognizer>{},
                      )
                      .putIfAbsent(
                        spanIndex,
                        () =>
                            TapGestureRecognizer()
                              ..onTap = () => _openHref(span.href!),
                      ),
          );
        }).toList(),
      ),
      textAlign: align,
    );
  }

  Widget _image(ReaderDocumentBlock block) {
    final id = block.resourceId;
    if (id == null) {
      return Builder(
        builder: (context) =>
            _imageFailurePlaceholder(context, block, missing: true),
      );
    }
    final future = _resources.putIfAbsent(
      id,
      () => widget.dataSource.loadResourceBytes(id),
    );
    return FutureBuilder<Uint8List?>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          if (_reportedResourceErrors.add(id)) {
            _reportFailure(
              snapshot.error!,
              'document_resource',
              ReaderFailureKind.image,
            );
          }
          return _imageFailurePlaceholder(context, block, missing: false);
        }
        final bytes = snapshot.data;
        if (bytes == null && snapshot.connectionState != ConnectionState.done) {
          return const SizedBox(
            height: 32,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        if (bytes == null) {
          return _imageFailurePlaceholder(context, block, missing: true);
        }
        final int retryCount = _resourceRetryCounts[id] ?? 0;
        final isSvg =
            bytes.length > 4 &&
            String.fromCharCodes(
              bytes.take(512),
            ).toLowerCase().contains('<svg');
        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width,
            ),
            child: isSvg
                ? SvgPicture.memory(
                    bytes,
                    key: ValueKey((id, retryCount)),
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, _) {
                      _reportImageFailure(id, error);
                      return _imageFailurePlaceholder(
                        context,
                        block,
                        missing: false,
                      );
                    },
                  )
                : Image(
                    key: ValueKey((id, retryCount)),
                    image: ResizeImage(
                      MemoryImage(bytes),
                      width: 1536,
                      height: 1536,
                      policy: ResizeImagePolicy.fit,
                    ),
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, _) {
                      _reportImageFailure(id, error);
                      return _imageFailurePlaceholder(
                        context,
                        block,
                        missing: false,
                      );
                    },
                  ),
          ),
        );
      },
    );
  }

  void _reportImageFailure(String id, Object error) {
    if (_reportedResourceErrors.add(id)) {
      _reportFailure(error, 'document_resource', ReaderFailureKind.image);
    }
  }

  Widget _imageFailurePlaceholder(
    BuildContext context,
    ReaderDocumentBlock block, {
    required bool missing,
  }) {
    final alt =
        (block.text.isNotEmpty
                ? block.text
                : block.style['alt'] as String? ?? '')
            .trim();
    final foreground = _foreground;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Container(
        width: double.infinity,
        constraints: const BoxConstraints(minHeight: 76),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: foreground.withValues(alpha: .04),
          border: Border.all(color: foreground.withValues(alpha: .18)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(
              Icons.broken_image_outlined,
              color: foreground.withValues(alpha: .65),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    missing ? '图片资源缺失' : '图片加载失败',
                    style: TextStyle(
                      color: foreground,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    alt.isEmpty ? '无替代文本' : alt,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: foreground.withValues(alpha: .75)),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: block.resourceId == null
                  ? null
                  : () => _retryResource(block.resourceId!),
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  double _cssFontSize(Object? value, double fallback) {
    if (value is num) return value.toDouble().clamp(10, 64);
    if (value is! String) return fallback;
    final match = RegExp(
      r'^\s*([0-9]+(?:\.[0-9]+)?)\s*(em|rem|%)?\s*$',
    ).firstMatch(value);
    if (match == null) return fallback;
    final amount = double.tryParse(match.group(1)!) ?? 1;
    final factor = switch (match.group(2)) {
      'em' || 'rem' => amount,
      '%' => amount / 100,
      _ => amount / fallback,
    };
    return (fallback * factor).clamp(fallback * .65, fallback * 2.5);
  }

  double _cssLineHeight(Object? value, double fallback) {
    if (value is num) return value.toDouble().clamp(1, 3);
    if (value is! String) return fallback;
    final raw = value.trim();
    final number = double.tryParse(raw.replaceAll('%', ''));
    if (number == null) return fallback;
    final ratio = raw.endsWith('%') ? number / 100 : number;
    return ratio.clamp(1, 3);
  }

  double _cssIndent(Object? value, double fontSize) {
    if (value is num) return value.toDouble().clamp(0, 192);
    if (value is! String) return 0;
    final match = RegExp(
      r'^\s*([0-9]+(?:\.[0-9]+)?)\s*(em|px|%)?\s*$',
    ).firstMatch(value);
    if (match == null) return 0;
    final amount = double.tryParse(match.group(1)!) ?? 0;
    final pixels = switch (match.group(2)) {
      'em' => amount * fontSize,
      '%' => amount * fontSize / 100,
      _ => amount,
    };
    return pixels.clamp(0, 192);
  }

  FontWeight _cssFontWeight(Object? value) {
    if (value == 'bold' || value == 'bolder') return FontWeight.bold;
    final numeric = value is String ? int.tryParse(value) : value;
    if (numeric is num && numeric >= 600) return FontWeight.bold;
    return FontWeight.normal;
  }

  TextAlign? _cssTextAlign(Object? value) => switch (value) {
    'center' => TextAlign.center,
    'right' || 'end' => TextAlign.right,
    'justify' => TextAlign.justify,
    'left' || 'start' => TextAlign.left,
    _ => null,
  };

  Color? _cssColor(Object? value) {
    if (value is! String) return null;
    final color = value.trim().toLowerCase();
    const names = <String, Color>{
      'black': Colors.black,
      'white': Colors.white,
      'red': Colors.red,
      'blue': Colors.blue,
      'green': Colors.green,
      'gray': Colors.grey,
      'grey': Colors.grey,
      'transparent': Colors.transparent,
    };
    if (names[color] case final Color named) return named;
    if (!color.startsWith('#')) return null;
    final digits = color.substring(1);
    if (digits.length == 3) {
      final expanded = digits.split('').map((digit) => '$digit$digit').join();
      return Color(int.tryParse('ff$expanded', radix: 16) ?? 0xff000000);
    }
    if (digits.length == 6) {
      return Color(int.tryParse('ff$digits', radix: 16) ?? 0xff000000);
    }
    if (digits.length == 8) {
      return Color(int.tryParse(digits, radix: 16) ?? 0xff000000);
    }
    return null;
  }
}
