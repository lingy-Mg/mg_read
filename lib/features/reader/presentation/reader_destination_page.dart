import 'package:flutter/material.dart';

/// Typed-route destination before M5 resolves a reader launch request.
///
/// The stable [bookId] is intentionally not rendered or used to load content.
/// This keeps M2.1 routing independent of any future source, database, or
/// ReaderHostPage dependency.
class ReaderDestinationPage extends StatelessWidget {
  /// Creates a destination for a stable host-owned [bookId].
  const ReaderDestinationPage({required this.bookId, super.key});

  /// Stable identifier to be resolved by a future application use case.
  final String bookId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('阅读会话尚未就绪')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                '此路由只保存稳定书籍 ID。后续由应用用例解析数据源和状态存储后再打开阅读器。',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
