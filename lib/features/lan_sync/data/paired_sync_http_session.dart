/// 已配对 HTTP 会话交换、清单规划和有界请求辅助。
///
/// 作为 paired_sync_transport.dart 的私有实现部分，不建立新的公开边界。
part of 'paired_sync_transport.dart';

const int _parallelPluginTaskLimit = 3;

extension _CompleterCompletion<T> on Completer<T> {
  void completeIfPending([FutureOr<T>? value]) {
    if (!isCompleted) complete(value);
  }
}

final class _HttpExchange {
  _HttpExchange({
    required this.id,
    required this.peer,
    required this.remoteManifestRaw,
    required this.remotePolicy,
    required this.requestId,
  }) {
    for (final future in <Future<Object?>>[
      negotiation.future,
      uploadsDone.future,
      uploadPrepared.future,
      uploadReady.future,
      serverApplied.future,
      clientApplied.future,
    ]) {
      unawaited(future.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    }
  }

  final String id;
  final PairedDevice peer;
  final Object? remoteManifestRaw;
  final _WirePolicy remotePolicy;
  final String? requestId;
  final Completer<Map<String, Object?>> negotiation = Completer<Map<String, Object?>>();
  final Completer<void> uploadsDone = Completer<void>();
  final Completer<void> uploadPrepared = Completer<void>();
  final Completer<void> uploadReady = Completer<void>();
  final Completer<_AppliedSummary> serverApplied = Completer<_AppliedSummary>();
  final Completer<_AppliedSummary> clientApplied = Completer<_AppliedSummary>();
  final Set<String> receivedIds = <String>{};
  final Map<String, LanSyncPluginDescriptor> uploadDescriptors = <String, LanSyncPluginDescriptor>{};
  final Map<String, Future<LanSyncHttpArtifact>> artifacts = <String, Future<LanSyncHttpArtifact>>{};
  LanSyncGateway? gateway;
  LanSyncManifest? localManifest;
  _ImportPlan? plan;
  bool closed = false;
  String stage = 'request';

  LanSyncManifest get remoteManifest => _manifest(remoteManifestRaw);

  void configure(LanSyncGateway value, LanSyncManifest manifest, _ImportPlan importPlan) {
    gateway = value;
    localManifest = manifest;
    plan = importPlan;
  }

  Future<void> acceptUpload(String encodedId, HttpRequest request) async {
    final pluginId = Uri.decodeComponent(encodedId);
    final selected = plan?.selection.pluginIds ?? const <String>{};
    final plugin = uploadDescriptors[pluginId];
    if (receivedIds.contains(pluginId)) {
      await request.drain<void>();
      return;
    }
    if (plugin == null ||
        !selected.contains(pluginId) ||
        request.headers.value(LanSyncHttpAuthentication.contentHashHeader) != plugin.sha256 ||
        (request.contentLength >= 0 && request.contentLength != plugin.bytes)) {
      throw const LanSyncTransportException('lan_sync_plugin_descriptor_invalid');
    }
    final artifact = await LanSyncHttpArtifact.materialize(plugin, request);
    try {
      await gateway!.importPluginArchive(plugin, artifact.openRead());
      receivedIds.add(pluginId);
    } finally {
      await artifact.close();
    }
  }

  void acceptUploadDescriptors(Object? raw) {
    if (raw is! List) throw const LanSyncTransportException('lan_sync_plugin_descriptor_invalid');
    final selected = plan?.selection.pluginIds ?? const <String>{};
    for (final value in raw) {
      if (value is! Map) throw const LanSyncTransportException('lan_sync_plugin_descriptor_invalid');
      final plugin = LanSyncPluginDescriptor.fromJson(value.map<String, Object?>((key, value) => MapEntry(key as String, value)));
      final offered = remoteManifest.plugins.where((item) => item.id == plugin.id).firstOrNull;
      if (offered == null || !selected.contains(plugin.id) || !_sameLogical(plugin, offered)) {
        throw const LanSyncTransportException('lan_sync_plugin_descriptor_invalid');
      }
      uploadDescriptors[plugin.id] = plugin;
    }
    if (uploadDescriptors.length != selected.length) {
      throw const LanSyncTransportException('lan_sync_transfer_incomplete');
    }
  }

  Future<LanSyncHttpArtifact> artifact(String encodedId) {
    final pluginId = Uri.decodeComponent(encodedId);
    final plugin = localManifest!.plugins.where((item) => item.id == pluginId).firstOrNull;
    if (plugin == null) throw const LanSyncTransportException('lan_sync_plugin_unexpected');
    return artifacts.putIfAbsent(pluginId, () async {
      final materialized = await _materialize(gateway!, plugin);
      if (!_sameLogical(materialized.descriptor, plugin)) {
        throw const LanSyncTransportException('lan_sync_plugin_version_changed');
      }
      return LanSyncHttpArtifact.materialize(materialized.descriptor, materialized.bytes);
    });
  }

  Future<void> rejectBusy() async {
    fail(
      const PairedSyncPeerFailureException(code: 'lan_sync_peer_busy', stage: 'request', errorText: 'lan_sync_peer_busy'),
      StackTrace.current,
    );
  }

  void expire() {
    fail(const LanSyncTransportException('lan_sync_session_expired'), StackTrace.current);
  }

  void fail(Object error, StackTrace stack) {
    if (closed) return;
    final failure = error is PairedSyncPeerFailureException
        ? error
        : PairedSyncPeerFailureException(code: _sessionFailureCode(stage, error), stage: stage, errorText: _boundedError(error));
    if (!negotiation.isCompleted) negotiation.completeError(failure, stack);
    if (!uploadsDone.isCompleted) uploadsDone.completeError(failure, stack);
    if (!uploadPrepared.isCompleted) uploadPrepared.completeError(failure, stack);
    if (!uploadReady.isCompleted) uploadReady.completeError(failure, stack);
    if (!serverApplied.isCompleted) serverApplied.completeError(failure, stack);
    if (!clientApplied.isCompleted) clientApplied.completeError(failure, stack);
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    for (final future in artifacts.values) {
      try {
        await (await future).close();
      } on Object {
        // Session artifacts may already be gone after an interrupted request.
      }
    }
  }
}

final class _Selection {
  const _Selection(this.pluginIds, this.shelfItemIds);

  final Set<String> pluginIds;
  final Set<String> shelfItemIds;

  Map<String, Object?> toJson() => <String, Object?>{'pluginIds': pluginIds.toList(), 'shelfItemIds': shelfItemIds.toList()};

  factory _Selection.fromJson(Object? raw, LanSyncManifest manifest) {
    if (raw is! Map) throw const LanSyncTransportException('lan_sync_selection_invalid');
    final plugins = raw['pluginIds'];
    final shelf = raw['shelfItemIds'];
    if (plugins is! List || shelf is! List || plugins.any((value) => value is! String) || shelf.any((value) => value is! String)) {
      throw const LanSyncTransportException('lan_sync_selection_invalid');
    }
    final result = _Selection(plugins.cast<String>().toSet(), shelf.cast<String>().toSet());
    if (!manifest.plugins.map((item) => item.id).toSet().containsAll(result.pluginIds) ||
        !manifest.shelfItems.map((item) => item.identity).toSet().containsAll(result.shelfItemIds)) {
      throw const LanSyncTransportException('lan_sync_selection_invalid');
    }
    return result;
  }
}

final class _ImportPlan {
  const _ImportPlan(this.developmentConflicts, this.preview, this.selection);
  final int developmentConflicts;
  final LanSyncImportPreview? preview;
  final _Selection selection;
}

final class _AppliedSummary {
  const _AppliedSummary(this.books, this.developmentConflicts, this.plugins);
  final int books;
  final int developmentConflicts;
  final int plugins;
  Map<String, Object?> toJson() => <String, Object?>{'books': books, 'developmentConflicts': developmentConflicts, 'plugins': plugins};
  factory _AppliedSummary.fromJson(Map<String, Object?> json) =>
      _AppliedSummary(json['books'] as int, json['developmentConflicts'] as int, json['plugins'] as int);
}

final class _WirePolicy {
  const _WirePolicy({required this.canReceive, required this.canSend, required this.syncBookshelf, required this.syncPlugins});
  final bool canReceive;
  final bool canSend;
  final bool syncBookshelf;
  final bool syncPlugins;

  factory _WirePolicy.fromDevice(PairedDevice device, PairedSyncOperation operation) => _WirePolicy(
    canReceive: device.canReceive && operation.receives,
    canSend: device.canSend && operation.sends,
    syncBookshelf: device.syncBookshelf,
    syncPlugins: device.syncPlugins,
  );

  factory _WirePolicy.fromJson(Map<String, Object?> json) {
    final values = <Object?>[json['canReceive'], json['canSend'], json['syncBookshelf'], json['syncPlugins']];
    if (values.any((value) => value is! bool)) throw const LanSyncTransportException('lan_sync_policy_invalid');
    return _WirePolicy(
      canReceive: json['canReceive']! as bool,
      canSend: json['canSend']! as bool,
      syncBookshelf: json['syncBookshelf']! as bool,
      syncPlugins: json['syncPlugins']! as bool,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'canReceive': canReceive,
    'canSend': canSend,
    'syncBookshelf': syncBookshelf,
    'syncPlugins': syncPlugins,
  };
}

Future<_ImportPlan> _planImport(LanSyncGateway gateway, LanSyncManifest manifest) async {
  if (manifest.plugins.isEmpty && manifest.shelfItems.isEmpty) {
    return const _ImportPlan(0, null, _Selection(<String>{}, <String>{}));
  }
  final preview = await gateway.previewImport(manifest, force: true);
  return _ImportPlan(
    preview.pluginPlans.values.where((state) => state == LanSyncPluginPlanState.developmentConflict).length,
    preview,
    _Selection(preview.recommendedPluginIds, preview.selectedShelfItemIds),
  );
}

Future<LanSyncManifest> _createManifest(LanSyncGateway gateway, _WirePolicy policy) async {
  if (gateway is LanSyncPairedGateway) {
    return (gateway as LanSyncPairedGateway).createPairedManifest(
      includePlugins: policy.canSend && policy.syncPlugins,
      includeShelf: policy.canSend && policy.syncBookshelf,
      deferPluginArtifacts: true,
    );
  }
  final manifest = await gateway.createManifest();
  return LanSyncManifest(
    plugins: policy.canSend && policy.syncPlugins ? manifest.plugins : const <LanSyncPluginDescriptor>[],
    shelfItems: policy.canSend && policy.syncBookshelf ? manifest.shelfItems : const <LanSyncShelfItem>[],
    skippedShelfItems: policy.canSend && policy.syncBookshelf ? manifest.skippedShelfItems : 0,
  );
}

Future<LanSyncMaterializedPlugin> _materialize(LanSyncGateway gateway, LanSyncPluginDescriptor plugin) => gateway is LanSyncPairedGateway
    ? (gateway as LanSyncPairedGateway).materializePluginArchive(plugin)
    : gateway.openPluginArchive(plugin).then((bytes) => LanSyncMaterializedPlugin(descriptor: plugin, bytes: bytes));

bool _sameLogical(LanSyncPluginDescriptor actual, LanSyncPluginDescriptor offered) =>
    actual.id == offered.id &&
    actual.version == offered.version &&
    actual.artifactFormat == offered.artifactFormat &&
    actual.developmentFingerprint == offered.developmentFingerprint &&
    actual.developmentRevision == offered.developmentRevision &&
    actual.provenance == offered.provenance &&
    actual.transferable &&
    !actual.deferred;

Future<_AppliedSummary> _finishApply(LanSyncGateway gateway, LanSyncManifest manifest, _ImportPlan plan, {Set<String>? receivedIds}) async {
  if (receivedIds != null && !receivedIds.containsAll(plan.selection.pluginIds)) {
    throw const LanSyncTransportException('lan_sync_transfer_incomplete');
  }
  final plugins = plan.selection.pluginIds.isEmpty ? const LanSyncPluginImportResult.empty() : await gateway.finishPluginImports();
  if (plugins.failed > 0) throw LanSyncGatewayException(plugins.failureCode ?? 'lan_sync_plugin_import_failed');
  if (plan.preview == null) return _AppliedSummary(0, plan.developmentConflicts, 0);
  final applied = await gateway.applyImport(
    manifest: manifest.selectShelfItems(plan.selection.shelfItemIds),
    conflictChoices: {for (final conflict in plan.preview!.conflicts) conflict.identity: LanSyncConflictChoice.smartMerge},
    availablePluginIds: plugins.availablePluginIds,
    pluginResult: plugins,
    force: true,
  );
  return _AppliedSummary(applied.added + applied.updated, plan.developmentConflicts, applied.pluginInstalled);
}

LanSyncManifest _manifest(Object? raw) {
  if (raw is! Map) throw const LanSyncTransportException('lan_sync_manifest_invalid');
  try {
    return LanSyncManifest.fromPairedTasksJson(raw.map<String, Object?>((key, value) => MapEntry(key as String, value)));
  } on FormatException catch (error) {
    throw LanSyncTransportException('lan_sync_manifest_invalid', reason: error.message.toString());
  }
}

Future<Map<String, Object?>> _readAuthenticatedJson(HttpRequest request) async {
  final bytes = await request.fold<List<int>>(<int>[], (buffer, chunk) {
    if (buffer.length + chunk.length > lanSyncMaxManifestBytes) {
      throw const LanSyncTransportException('lan_sync_control_too_large');
    }
    return buffer..addAll(chunk);
  });
  if (request.headers.value(LanSyncHttpAuthentication.contentHashHeader) != LanSyncHttpAuthentication.bodyHash(bytes)) {
    throw const LanSyncTransportException('lan_sync_http_body_invalid');
  }
  if (bytes.isEmpty) return <String, Object?>{};
  final value = jsonDecode(utf8.decode(bytes));
  if (value is! Map) throw const LanSyncTransportException('lan_sync_control_invalid');
  return value.map<String, Object?>((key, value) => MapEntry(key as String, value));
}

Future<Map<String, Object?>> _jsonRequest(
  HttpClient client,
  Uri uri,
  String method,
  Map<String, Object?>? value,
  String deviceId,
  List<int> secret, {
  bool allowEmpty = false,
}) async {
  final bytes = value == null ? const <int>[] : utf8.encode(jsonEncode(value));
  final request = await client.openUrl(method, uri);
  LanSyncHttpAuthentication.sign(
    request,
    deviceId: deviceId,
    sharedSecret: secret,
    contentSha256: LanSyncHttpAuthentication.bodyHash(bytes),
  );
  request.headers.contentType = ContentType.json;
  request.contentLength = bytes.length;
  request.add(bytes);
  final response = await request.close();
  final responseBytes = await response.fold<List<int>>(<int>[], (buffer, chunk) => buffer..addAll(chunk));
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw _httpFailure(response.statusCode, responseBytes);
  }
  if (responseBytes.isEmpty && allowEmpty) return <String, Object?>{};
  final decoded = jsonDecode(utf8.decode(responseBytes));
  if (decoded is! Map) throw const LanSyncTransportException('lan_sync_control_invalid');
  return decoded.map<String, Object?>((key, value) => MapEntry(key as String, value));
}

Exception _httpFailure(int statusCode, List<int> responseBytes) {
  Map<String, Object?>? failure;
  try {
    final decoded = jsonDecode(utf8.decode(responseBytes));
    if (decoded is Map) failure = decoded.map<String, Object?>((key, value) => MapEntry(key as String, value));
  } on Object {
    // Invalid peer error bodies are reduced to the HTTP status.
  }
  if (failure?['code'] is String && failure?['stage'] is String && failure?['errorText'] is String) {
    return PairedSyncPeerFailureException(
      code: failure!['code']! as String,
      stage: failure['stage']! as String,
      errorText: failure['errorText']! as String,
    );
  }
  return LanSyncTransportException('lan_sync_http_failed', reason: failure?['detail']?.toString() ?? 'status_$statusCode');
}

Future<void> _runBoundedPluginTasks(int taskCount, Future<void> Function(int index) task) async {
  var next = 0;
  Future<void> worker() async {
    while (next < taskCount) {
      final index = next++;
      await task(index);
    }
  }

  await Future.wait(<Future<void>>[for (var index = 0; index < min(taskCount, _parallelPluginTaskLimit); index++) worker()]);
}

Future<void> _respond(HttpResponse response, int status, Map<String, Object?>? value) async {
  response.statusCode = status;
  if (value != null) {
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(value));
  }
  await response.close();
}

int _httpStatus(Object error) =>
    error is LanSyncTransportException && error.code == 'lan_sync_peer_busy' ? HttpStatus.serviceUnavailable : HttpStatus.badRequest;

String _errorCode(Object error) => error is LanSyncTransportException ? error.code : 'device_sync_http_failed';

String _sessionFailureCode(String stage, Object error) {
  if (error is PairedSyncPeerFailureException) return error.code;
  if (error is LanSyncTransportException) return error.code;
  if (error is LanSyncGatewayException) return 'lan_sync_${stage}_${error.code}';
  return 'device_sync_${stage}_failed';
}

String _boundedError(Object error) {
  final value = error.toString();
  return value.length <= 512 ? value : value.substring(0, 512);
}

String? _validDeviceLabel(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim();
  return normalized.isEmpty || normalized.length > 128 ? null : normalized;
}

bool _eligiblePeer(InternetAddress? address) =>
    address != null && address.type == InternetAddressType.IPv4 && isLanSyncPrivateIpv4(address.address);

bool _validNonce(Object? value) =>
    value is String && value.length >= 20 && value.length <= 64 && RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);

String _randomToken(int length) {
  final random = Random.secure();
  return base64Url.encode(List<int>.generate(length, (_) => random.nextInt(256), growable: false)).replaceAll('=', '');
}
