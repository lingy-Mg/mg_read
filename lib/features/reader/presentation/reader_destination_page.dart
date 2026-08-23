import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

import 'package:mg_read/features/library/application/library_page_controller.dart';
import 'package:mg_read/features/reader/application/library_reader_launcher.dart';
import 'package:mg_read/features/reader/application/reader_launch_failure.dart';
import 'package:mg_read/features/reader/application/reader_launch_request.dart';
import 'package:mg_read/features/reader/presentation/reader_host_page.dart';

/// Resolves a stable shelf ID into the reader's data source and state store.
class ReaderDestinationPage extends ConsumerStatefulWidget {
  const ReaderDestinationPage({required this.bookId, super.key});

  /// Stable, app-owned bookshelf identifier carried by the route.
  final String bookId;

  @override
  ConsumerState<ReaderDestinationPage> createState() =>
      _ReaderDestinationPageState();
}

class _ReaderDestinationPageState extends ConsumerState<ReaderDestinationPage> {
  ReaderLaunchRequest? _request;
  Object? _error;
  var _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_resolve());
  }

  Future<void> _resolve() async {
    final generation = ++_generation;
    setState(() {
      _request = null;
      _error = null;
    });
    try {
      final request = await ref
          .read(libraryReaderLauncherProvider)
          .launch(widget.bookId, observer: _ReaderExitObserver(_leaveReader));
      if (!mounted || generation != _generation) return;
      setState(() => _request = request);
    } on Object catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() => _error = error);
    }
  }

  Future<void> _leaveReader(ReaderProgress? progress) async {
    await ref.read(libraryPageControllerProvider.notifier).refresh();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final request = _request;
    if (request != null) return ReaderHostPage(request: request);
    final error = _error;
    if (error != null) {
      final failure = ReaderLaunchFailure.fromError(error);
      return Scaffold(
        appBar: AppBar(title: const Text('暂时无法开始阅读')),
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(failure.reason.userMessage),
                  const SizedBox(height: 8),
                  Text('诊断代码：${failure.diagnosticCode}'),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () => unawaited(_resolve()),
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return Scaffold(
      body: Center(
        child: Semantics(label: '正在准备阅读内容', child: CircularProgressIndicator()),
      ),
    );
  }
}

final class _ReaderExitObserver extends ReaderObserver {
  const _ReaderExitObserver(this._onExitRequested);

  final Future<void> Function(ReaderProgress? progress) _onExitRequested;

  @override
  Future<void> onExitRequested(ReaderProgress? progress) =>
      _onExitRequested(progress);
}
