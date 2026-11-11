/// 阅读失败的可选中文本与复制入口；只展示宿主保留的错误链，不执行内容 IO。
/// 复制失败保留原始错误，长内容由外层失败页面滚动容纳。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/models.dart';

class ReaderFailureDetails extends StatelessWidget {
  const ReaderFailureDetails({
    required this.failure,
    required this.bookId,
    this.bookTitle,
    required this.color,
    super.key,
  });

  final ReaderFailure failure;
  final String bookId;
  final String? bookTitle;
  final Color color;

  String get _details {
    final lines = <String>[
      if (bookTitle != null) '书籍：$bookTitle',
      '书籍标识：$bookId',
    ];
    Object? current = failure;
    final seen = Set<Object>.identity();
    for (
      var depth = 0;
      current != null && depth < 5 && seen.add(current);
      depth++
    ) {
      if (current is ReaderFailure) {
        lines.addAll(<String>[
          '错误原因：${current.message}',
          if (current.code != null) '错误码：${current.code}',
          if (current.location != null) '失败位置：${current.location}',
        ]);
        current = current.cause;
      } else {
        lines.add('底层原因：$current');
        break;
      }
    }
    return lines.join('\n');
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      SelectableText(
        _details,
        key: const Key('reader-failure-details'),
        style: TextStyle(color: color, fontSize: 12),
      ),
      TextButton.icon(
        key: const Key('reader-copy-error'),
        onPressed: () async {
          var message = '错误详情已复制';
          try {
            await Clipboard.setData(ClipboardData(text: _details));
          } catch (_) {
            message = '复制失败，请长按或选中错误详情复制';
          }
          if (context.mounted) {
            ScaffoldMessenger.maybeOf(
              context,
            )?.showSnackBar(SnackBar(content: Text(message)));
          }
        },
        icon: const Icon(Icons.copy_rounded, size: 16),
        label: const Text('复制错误详情'),
      ),
    ],
  );
}
