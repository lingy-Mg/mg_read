/// File picker and open-with ingress. Android sources stream bounded native
/// SAF chunks; desktop exposes an internal path adapter to File.openRead.
library;

import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mg_read/core/content_library/content_library.dart';

class LocalImportIngress {
  LocalImportIngress._() {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  static final LocalImportIngress instance = LocalImportIngress._();
  static const MethodChannel _channel = MethodChannel('mg_read/local_import');
  final StreamController<List<LocalImportInput>> _pending = StreamController.broadcast();
  final Map<String, int?> _tokenSizes = <String, int?>{};
  final Map<LocalImportInput, String> _inputTokens = <LocalImportInput, String>{};
  final List<List<LocalImportInput>> _buffered = <List<LocalImportInput>>[];
  final Set<String> _seenOpenedTokens = <String>{};
  Stream<List<LocalImportInput>> get pendingInputs => _pending.stream;

  /// Install the channel before launch arguments are queued. Calling again
  /// after subscribing drains Android cold-start intents.
  Future<void> install() => drainPending();

  List<List<LocalImportInput>> takeBufferedInputs() {
    final buffered = List<List<LocalImportInput>>.of(_buffered);
    _buffered.clear();
    return buffered;
  }

  Future<List<LocalImportInput>> pickDocuments() async {
    if (Platform.isAndroid) {
      final values = await _channel.invokeListMethod<Object?>('pickFiles', <String, Object?>{'kind': 'documents'});
      return _nativeInputs(values ?? const <Object?>[]);
    }
    if (!(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) return const <LocalImportInput>[];
    final files = await openFiles(
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(label: 'TXT 和 EPUB', extensions: <String>['txt', 'epub']),
      ],
    );
    return <LocalImportInput>[
      for (final file in files)
        LocalImportInput(fileName: file.name, bytes: File(file.path).lengthSync(), openRead: () => File(file.path).openRead()),
    ];
  }

  Future<List<LocalImportInput>> pickImages() async {
    if (Platform.isAndroid) {
      final values = await _channel.invokeListMethod<Object?>('pickFiles', <String, Object?>{'kind': 'image'});
      return _nativeInputs(values ?? const <Object?>[]);
    }
    if (!(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) return const <LocalImportInput>[];
    final files = await openFiles(
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(label: '图片', extensions: <String>['png', 'jpg', 'jpeg', 'webp']),
      ],
    );
    return <LocalImportInput>[
      for (final file in files)
        LocalImportInput(fileName: file.name, bytes: File(file.path).lengthSync(), openRead: () => File(file.path).openRead()),
    ];
  }

  Future<void> releaseInput(LocalImportInput input) async {
    final token = _inputTokens.remove(input);
    if (token == null) return;
    _tokenSizes.remove(token);
    try {
      await _channel.invokeMethod<void>('release', <String, Object?>{'token': token});
    } on Object {
      // Activity teardown also releases every native URI stream.
    }
  }

  Future<bool> registerOpenWith() async {
    if (!Platform.isWindows) return false;
    return await _channel.invokeMethod<bool>('registerOpenWith') ?? false;
  }

  Future<String?> createExport({required String fileName, required String mimeType}) async {
    if (!Platform.isAndroid) return null;
    final result = await _channel.invokeMapMethod<String, Object?>('createExport', <String, Object?>{
      'fileName': fileName,
      'mimeType': mimeType,
    });
    return result?['token'] as String?;
  }

  Future<void> writeExportChunk(String token, Uint8List bytes) async {
    if (bytes.length > 256 * 1024) throw ArgumentError.value(bytes.length, 'bytes.length', 'export chunks may not exceed 256 KiB');
    await _channel.invokeMethod<void>('writeChunk', <String, Object?>{'token': token, 'data': bytes});
  }

  Future<void> finishExport(String token, {required bool success}) =>
      _channel.invokeMethod<void>('finishExport', <String, Object?>{'token': token, 'success': success});

  /// Native window/app-open handlers pass either desktop paths or Android URI
  /// tokens. Maps are short-lived event payloads, never persistence records.
  void queuePaths(Object? value) {
    final paths = value is List ? value.whereType<String>().toList() : <String>[];
    if (paths.isNotEmpty) {
      _publish(<LocalImportInput>[
        for (final path in paths) LocalImportInput(fileName: path.split(RegExp(r'[/\\]')).last, openRead: () => File(path).openRead()),
      ]);
    }
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method != 'filesOpened') return;
    final values = call.arguments is List ? call.arguments as List : const <Object?>[];
    final inputs = _nativeInputs(values, markOpened: true);
    if (inputs.isNotEmpty) _publish(inputs);
    // Native retains an early-open backlog until acknowledged. Drain after a
    // warm event too, otherwise the hundred-entry backlog eventually fills.
    await drainPending();
  }

  List<LocalImportInput> _nativeInputs(List<Object?> values, {bool markOpened = false}) {
    final inputs = <LocalImportInput>[];
    for (final value in values) {
      if (value is! Map) continue;
      final item = Map<Object?, Object?>.from(value);
      final path = item['path'] as String?;
      final token = item['token'] as String?;
      final securityToken = item['securityToken'] as String?;
      final openId = item['openId'] as String?;
      final openedToken = token ?? securityToken ?? openId;
      if (markOpened && openedToken != null && !_seenOpenedTokens.add(openedToken)) continue;
      if (_seenOpenedTokens.length > 400) _seenOpenedTokens.remove(_seenOpenedTokens.first);
      final name = item['name'] as String? ?? (path == null ? '未命名文件' : path.split(RegExp(r'[/\\]')).last);
      final bytes = item['bytes'] as int?;
      if (path != null) {
        final input = LocalImportInput(fileName: name, bytes: bytes, openRead: () => File(path).openRead());
        if (securityToken != null) _inputTokens[input] = securityToken;
        inputs.add(input);
      } else if (token != null) {
        _tokenSizes[token] = bytes;
        final input = LocalImportInput(fileName: name, bytes: bytes, openRead: () => _readToken(token));
        _inputTokens[input] = token;
        inputs.add(input);
      }
    }
    return inputs;
  }

  Stream<List<int>> _readToken(String token) async* {
    var offset = 0;
    try {
      while (true) {
        final chunk = await _channel.invokeMapMethod<String, Object?>('readChunk', <String, Object?>{
          'token': token,
          'offset': offset,
          'maxBytes': 256 * 1024,
        });
        if (chunk == null) throw const LocalDocumentException('source_read_failed');
        final data = chunk['data'] as Uint8List? ?? Uint8List(0);
        if (data.isEmpty) break;
        offset += data.length;
        yield data;
        if (chunk['eof'] == true) break;
      }
    } finally {
      try {
        await _channel.invokeMethod<void>('close', <String, Object?>{'token': token});
      } on Object {
        // The platform also closes all handles when the Activity is destroyed.
      }
    }
  }

  Future<void> drainPending() async {
    if (!(Platform.isAndroid || Platform.isMacOS || Platform.isWindows)) return;
    try {
      final values = await _channel.invokeListMethod<Object?>('drainPending');
      final inputs = _nativeInputs(values ?? const <Object?>[], markOpened: true);
      if (inputs.isNotEmpty) _publish(inputs);
    } on MissingPluginException {
      // Platform ingress is not installed in widget tests and unsupported hosts.
    } on PlatformException {
      // Startup remains usable if a native ingress helper reports unavailable.
    }
  }

  void _publish(List<LocalImportInput> inputs) {
    if (_pending.hasListener) {
      _pending.add(inputs);
    } else {
      final count = _buffered.fold<int>(0, (total, batch) => total + batch.length);
      final available = (100 - count).clamp(0, 100);
      if (available > 0) _buffered.add(inputs.take(available).toList());
      for (final input in inputs.skip(available)) {
        unawaited(releaseInput(input));
      }
    }
  }

  @visibleForTesting
  void disposeForTesting() => _pending.close();
}
