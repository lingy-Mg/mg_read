import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/src/windows_job_object.dart';

import 'test_paths.dart';

void main() {
  test(
    'Windows Job Object terminates a Runtime child and its later descendant',
    () async {
      final repositoryRoot = nodeRuntimeRepositoryRoot;
      final node = File(
        <String>[
          repositoryRoot.path,
          'tools',
          'node-v24.16.0-win-x64',
          'node.exe',
        ].join(Platform.pathSeparator),
      );
      final fixture = File(
        <String>[
          repositoryRoot.path,
          'test',
          'fixtures',
          'job-parent.mjs',
        ].join(Platform.pathSeparator),
      );
      expect(await node.exists(), isTrue);
      expect(await fixture.exists(), isTrue);

      final job = WindowsJobObject.create();
      Process? parent;
      StreamSubscription<String>? output;
      try {
        parent = await Process.start(
          node.path,
          <String>[fixture.path],
          environment: _testEnvironment(),
          includeParentEnvironment: false,
          runInShell: false,
          workingDirectory: repositoryRoot.path,
        );
        // Assignment happens before the fixture can create its test descendant;
        // this proves that closing the Job terminates the whole owned tree.
        job.assignProcess(parent.pid);

        final parentReady = Completer<void>();
        final childPid = Completer<int>();
        output = parent.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
              final Object? record = jsonDecode(line);
              if (record is! Map<Object?, Object?>) {
                return;
              }
              switch (record['type']) {
                case 'job_parent_ready':
                  if (!parentReady.isCompleted) {
                    parentReady.complete();
                  }
                  break;
                case 'job_child':
                  final pid = record['pid'];
                  if (pid is int && !childPid.isCompleted) {
                    childPid.complete(pid);
                  }
                  break;
              }
            });

        await parentReady.future.timeout(const Duration(seconds: 5));
        parent.stdin.writeln('spawn');
        final spawnedPid = await childPid.future.timeout(
          const Duration(seconds: 5),
        );
        expect(WindowsJobObject.isProcessAlive(spawnedPid), isTrue);

        job.close();
        await parent.exitCode.timeout(const Duration(seconds: 5));
        await _expectProcessExit(spawnedPid);
      } finally {
        await output?.cancel();
        try {
          job.close();
        } on WindowsJobObjectException {
          // The first close owns process-tree termination; a cleanup retry is
          // intentionally harmless if the handle has already been released.
        }
        if (parent != null) {
          parent.kill();
        }
      }
    },
    skip: !Platform.isWindows,
  );
}

/// Matches the production launcher's minimal environment without inheriting PATH.
Map<String, String> _testEnvironment() {
  const allowedNames = <String>[
    'ComSpec',
    'SystemRoot',
    'TEMP',
    'TMP',
    'WINDIR',
  ];
  final inherited = Platform.environment;
  return <String, String>{
    for (final name in allowedNames)
      if (inherited[name] case final value?) name: value,
  };
}

/// Polls the FFI liveness probe until the Job-owned descendant has exited.
Future<void> _expectProcessExit(int processId) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    if (!WindowsJobObject.isProcessAlive(processId)) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  fail('The Job Object descendant process remained alive after Job close.');
}
