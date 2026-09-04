/// Test-only paths shared by the flattened Flutter and Node.js Runtime packages.
library;

import 'dart:io';

/// Sibling Node.js Runtime repository used by Facade integration tests.
Directory get nodeRuntimeRepositoryRoot {
  var current = Directory.current.absolute;
  for (var depth = 0; depth < 8; depth += 1) {
    for (final relativePath in const <String>[
      'mg_read_node_runtime/',
      'packages/mg_read_node_runtime/',
    ]) {
      final candidate = Directory.fromUri(current.uri.resolve(relativePath));
      if (File.fromUri(candidate.uri.resolve('package.json')).existsSync()) {
        return candidate;
      }
    }
    final parent = current.parent;
    if (parent.path == current.path) break;
    current = parent;
  }
  throw StateError('Cannot locate the sibling Node.js Runtime package.');
}

/// Flutter Runtime package root paired with [nodeRuntimeRepositoryRoot].
Directory get pluginRuntimeRepositoryRoot => Directory.fromUri(
  nodeRuntimeRepositoryRoot.parent.uri.resolve('mgread_plugin_runtime/'),
);
