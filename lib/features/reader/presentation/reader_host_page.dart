import 'package:flutter/material.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

import 'package:mg_read/features/reader/application/reader_launch_request.dart';

/// Application page that hosts the reader plugin through its public API.
class ReaderHostPage extends StatelessWidget {
  /// Creates a page for one resolved reader launch [request].
  const ReaderHostPage({required this.request, super.key});

  /// The main-application inputs for this reading session.
  final ReaderLaunchRequest request;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: TextReaderView(
        bookId: request.bookId,
        dataSource: request.dataSource,
        stateStore: request.stateStore,
        observer: request.observer,
        controller: request.controller,
        extensions: request.extensions,
      ),
    );
  }
}
