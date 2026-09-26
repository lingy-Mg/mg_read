part of mgread_plugin_runtime;

/// Owns one Node backend and one independent native backend in the same App.
/// Installed source IDs stay unique across both catalogs because the public
/// content API identifies sources by ID. Each backend keeps its own process,
/// installation root, resource server, and cancellation lifetime.
final class _HybridRuntimeSupervisor implements _RuntimeSupervisor {
  _HybridRuntimeSupervisor(this._node, this._native) {
    _diagnosticSubscriptions = <StreamSubscription<RuntimeDiagnostic>>[
      _node.diagnostics.listen(_diagnostics.add),
      _native.diagnostics.listen(_diagnostics.add),
    ];
    _initializationSubscriptions =
        <StreamSubscription<RuntimeInitializationProgress>>[
          _node.initialization.listen(_initialization.add),
          _native.initialization.listen(_initialization.add),
        ];
  }

  final _RuntimeSupervisor _node;
  final _NativeRuntimeSupervisor _native;
  final Map<String, PluginEngine> _owners = <String, PluginEngine>{};
  final StreamController<RuntimeDiagnostic> _diagnostics =
      StreamController<RuntimeDiagnostic>.broadcast();
  final StreamController<RuntimeInitializationProgress> _initialization =
      StreamController<RuntimeInitializationProgress>.broadcast();
  late final List<StreamSubscription<RuntimeDiagnostic>>
  _diagnosticSubscriptions;
  late final List<StreamSubscription<RuntimeInitializationProgress>>
  _initializationSubscriptions;

  Future<List<InstalledPlugin>> _list() async {
    final lists = await Future.wait(<Future<List<InstalledPlugin>>>[
      _node.invoke(const InstalledPluginsInvocation()),
      _native.invoke(const InstalledPluginsInvocation()),
    ]);
    final owners = <String, PluginEngine>{};
    for (final plugin in lists[0]) {
      owners[plugin.id] = PluginEngine.node;
    }
    for (final plugin in lists[1]) {
      if (owners.containsKey(plugin.id)) {
        throw PluginRuntimeException(
          'plugin_id_conflict',
          'Source ${plugin.id} is installed in both engines; source IDs must be unique.',
        );
      }
      owners[plugin.id] = PluginEngine.native;
    }
    _owners
      ..clear()
      ..addAll(owners);
    return List<InstalledPlugin>.unmodifiable(<InstalledPlugin>[
      ...lists[0],
      ...lists[1],
    ]);
  }

  Future<_RuntimeSupervisor> _owner(String id) async {
    var engine = _owners[id];
    if (engine == null) {
      await _list();
      engine = _owners[id];
    }
    if (engine == null) {
      throw PluginRuntimeException(
        'plugin_not_found',
        'Source $id is not installed.',
      );
    }
    return engine == PluginEngine.native ? _native : _node;
  }

  @override
  Future<T> invoke<T>(
    PluginInvocation<T> invocation, {
    PluginInvocationCancellation? cancellation,
  }) async {
    if (invocation is InstalledPluginsInvocation) {
      return await _list() as T;
    }
    if (invocation is RuntimeStatusInvocation) {
      final statuses = await Future.wait(<Future<RuntimeStatusResult>>[
        _node.invoke(const RuntimeStatusInvocation()),
        _native.invoke(const RuntimeStatusInvocation()),
      ]);
      final node = statuses[0];
      final native = statuses[1];
      await _list();
      return RuntimeStatusResult(
            arch: node.arch,
            isHealthy: node.isHealthy,
            memory: node.memory,
            nodeVersion: node.nodeVersion,
            platform: node.platform,
            plugins: <InstalledPlugin>[...node.plugins, ...native.plugins],
            runtimeVersion: node.runtimeVersion,
            runtimeKind: node.runtimeKind,
            uptimeMs: node.uptimeMs,
            nativeStatus: native,
          )
          as T;
    }
    if (invocation is PluginStartupRecoveryInvocation) {
      final results = await Future.wait(<Future<PluginStartupRecovery>>[
        _node.invoke(const PluginStartupRecoveryInvocation()),
        _native.invoke(const PluginStartupRecoveryInvocation()),
      ]);
      return PluginStartupRecovery(
            quarantinedCount:
                results[0].quarantinedCount + results[1].quarantinedCount,
          )
          as T;
    }
    if (invocation is UninstallAllPluginsInvocation) {
      await _node.invoke(const UninstallAllPluginsInvocation());
      await _native.invoke(const UninstallAllPluginsInvocation());
      _owners.clear();
      return null as T;
    }
    if (invocation is ClearAllPluginCachesInvocation) {
      final results = await Future.wait(<Future<PluginCacheClearResult>>[
        _node.invoke(const ClearAllPluginCachesInvocation()),
        _native.invoke(const ClearAllPluginCachesInvocation()),
      ]);
      return PluginCacheClearResult(
            items: <PluginCacheClearItem>[
              ...results[0].items,
              ...results[1].items,
            ],
          )
          as T;
    }
    if (invocation is PluginCacheUsageInvocation &&
        (invocation as PluginCacheUsageInvocation).pluginId == null) {
      final lists = await Future.wait(<Future<List<PluginCacheUsage>>>[
        _node.invoke(const PluginCacheUsageInvocation()),
        _native.invoke(const PluginCacheUsageInvocation()),
      ]);
      return <PluginCacheUsage>[...lists[0], ...lists[1]] as T;
    }
    if (invocation is PluginTransferListInvocation) {
      final lists = await Future.wait(<Future<List<PluginTransferArtifact>>>[
        _node.invoke(const PluginTransferListInvocation()),
        _native.invoke(const PluginTransferListInvocation()),
      ]);
      return <PluginTransferArtifact>[...lists[0], ...lists[1]] as T;
    }
    if (invocation is PluginTransferOfferListInvocation) {
      final lists = await Future.wait(<Future<List<PluginTransferOffer>>>[
        _node.invoke(const PluginTransferOfferListInvocation()),
        _native.invoke(const PluginTransferOfferListInvocation()),
      ]);
      return <PluginTransferOffer>[...lists[0], ...lists[1]] as T;
    }
    if (invocation is PluginTransferPlanInvocation) {
      return await _planArtifacts(invocation as PluginTransferPlanInvocation)
          as T;
    }
    if (invocation is PluginTransferOfferPlanInvocation) {
      return await _planOffers(invocation as PluginTransferOfferPlanInvocation)
          as T;
    }
    if (invocation is SourceResourceDecodeInvocation) {
      final route = _SourceResourceUrl.require(
        (invocation as SourceResourceDecodeInvocation).url,
      );
      final owner = await _owner(route.pluginId);
      if (!identical(
        owner,
        route.engine == PluginEngine.native ? _native : _node,
      )) {
        throw const PluginRuntimeException(
          'invalid_request',
          'Resource engine does not match its plugin.',
        );
      }
      return owner.invoke(invocation, cancellation: cancellation);
    }

    final id = invocation._wireParams['pluginId'];
    if (id is String) {
      final owner = await _owner(id);
      final result = await owner.invoke(invocation, cancellation: cancellation);
      if (invocation is UninstallPluginInvocation) _owners.remove(id);
      return result;
    }
    return _node.invoke(invocation, cancellation: cancellation);
  }

  Future<List<PluginTransferPlanItem>> _planArtifacts(
    PluginTransferPlanInvocation invocation,
  ) async {
    final installed = <String, InstalledPlugin>{
      for (final plugin in await _list()) plugin.id: plugin,
    };
    final unavailable = <String, PluginTransferPlanItem>{};
    for (final artifact in invocation.artifacts) {
      final receiver = installed[artifact.pluginId];
      if (receiver != null && receiver.engine != artifact.engine) {
        unavailable[artifact.pluginId] = PluginTransferPlanItem(
          action: PluginTransferPlanAction.unavailable,
          pluginId: artifact.pluginId,
          receiverVersion: receiver.activeVersion,
          version: artifact.version,
        );
      }
    }
    final result = <PluginTransferPlanItem>[];
    for (final engine in PluginEngine.values) {
      final subset = invocation.artifacts
          .where(
            (item) =>
                item.engine == engine &&
                !unavailable.containsKey(item.pluginId),
          )
          .toList();
      if (subset.isEmpty) continue;
      result.addAll(
        await (engine == PluginEngine.native ? _native : _node).invoke(
          PluginTransferPlanInvocation(
            artifacts: subset,
            forceUpgradePluginIds: invocation.forceUpgradePluginIds,
          ),
        ),
      );
    }
    return <PluginTransferPlanItem>[
      for (final artifact in invocation.artifacts)
        unavailable[artifact.pluginId] ??
            result.firstWhere((item) => item.pluginId == artifact.pluginId),
    ];
  }

  Future<List<PluginTransferPlanItem>> _planOffers(
    PluginTransferOfferPlanInvocation invocation,
  ) async {
    final installed = <String, InstalledPlugin>{
      for (final plugin in await _list()) plugin.id: plugin,
    };
    final unavailable = <String, PluginTransferPlanItem>{};
    for (final offer in invocation.offers) {
      final receiver = installed[offer.pluginId];
      if (receiver != null && receiver.engine != offer.engine) {
        unavailable[offer.pluginId] = PluginTransferPlanItem(
          action: PluginTransferPlanAction.unavailable,
          pluginId: offer.pluginId,
          receiverVersion: receiver.activeVersion,
          version: offer.version,
        );
      }
    }
    final result = <PluginTransferPlanItem>[];
    for (final engine in PluginEngine.values) {
      final subset = invocation.offers
          .where(
            (item) =>
                item.engine == engine &&
                !unavailable.containsKey(item.pluginId),
          )
          .toList();
      if (subset.isEmpty) continue;
      result.addAll(
        await (engine == PluginEngine.native ? _native : _node).invoke(
          PluginTransferOfferPlanInvocation(
            offers: subset,
            forceUpgradePluginIds: invocation.forceUpgradePluginIds,
          ),
        ),
      );
    }
    return <PluginTransferPlanItem>[
      for (final offer in invocation.offers)
        unavailable[offer.pluginId] ??
            result.firstWhere((item) => item.pluginId == offer.pluginId),
    ];
  }

  Future<bool> importNativeLocalPlugin() async {
    final bool imported;
    if (Platform.isAndroid) {
      imported = await _native.pickAndImportLocalPlugin();
    } else {
      final file = await openFile(
        acceptedTypeGroups: <XTypeGroup>[
          XTypeGroup(label: 'MgRead 原生数据源', extensions: <String>['mgplugin']),
        ],
        confirmButtonText: '导入',
      );
      if (file == null) return false;
      await _native.importLocalPlugin(file.path);
      imported = true;
    }
    if (imported) await _list();
    return imported;
  }

  Future<void> importLocalPluginForTesting(String sourcePath) async {
    final lowerPath = sourcePath.toLowerCase();
    if (lowerPath.endsWith('.mgplugin') &&
        !lowerPath.endsWith('.mgplugin.js')) {
      await _native.importLocalPlugin(sourcePath);
    } else {
      await _node.importLocalPlugin(sourcePath);
    }
    await _list();
  }

  @override
  Future<void> importLocalPlugin(String sourcePath) async {
    await _node.importLocalPlugin(sourcePath);
    await _list();
  }

  @override
  Future<bool> pickAndImportLocalPlugin() async {
    final imported = await _node.pickAndImportLocalPlugin();
    if (imported) await _list();
    return imported;
  }

  @override
  Future<Stream<List<int>>> exportPluginArtifact(
    PluginTransferArtifact artifact,
  ) => (artifact.engine == PluginEngine.native ? _native : _node)
      .exportPluginArtifact(artifact);

  @override
  Future<MaterializedPluginArtifact> materializePluginArtifact(
    PluginTransferOffer offer,
  ) => (offer.engine == PluginEngine.native ? _native : _node)
      .materializePluginArtifact(offer);

  @override
  Future<PluginDevelopmentPackage> packageDevelopmentPlugin(
    String pluginId,
    String directoryPath,
  ) => _node.packageDevelopmentPlugin(pluginId, directoryPath);

  @override
  Future<List<PluginTransferImportResult>> importPluginArtifacts(
    List<({PluginTransferArtifact artifact, Stream<List<int>> bytes})>
    artifacts, {
    Set<String> forceUpgradePluginIds = const <String>{},
  }) async {
    await _list();
    final incomingIds = <String>{};
    for (final item in artifacts) {
      final artifact = item.artifact;
      if (!incomingIds.add(artifact.pluginId)) {
        throw const PluginRuntimeException(
          'invalid_request',
          'A transfer batch cannot contain the same source twice.',
        );
      }
      final owner = _owners[artifact.pluginId];
      if (owner != null && owner != artifact.engine) {
        throw PluginRuntimeException(
          'plugin_id_conflict',
          'Source ${artifact.pluginId} is already installed in another engine.',
        );
      }
    }
    final result = <PluginTransferImportResult>[];
    for (final engine in PluginEngine.values) {
      final subset = artifacts
          .where((item) => item.artifact.engine == engine)
          .toList();
      if (subset.isEmpty) continue;
      result.addAll(
        await (engine == PluginEngine.native ? _native : _node)
            .importPluginArtifacts(
              subset,
              forceUpgradePluginIds: forceUpgradePluginIds,
            ),
      );
    }
    await _list();
    return <PluginTransferImportResult>[
      for (final artifact in artifacts)
        result.firstWhere(
          (item) => item.pluginId == artifact.artifact.pluginId,
        ),
    ];
  }

  @override
  Future<void> setDevelopmentDirectory(String path) =>
      _node.setDevelopmentDirectory(path);

  @override
  Stream<RuntimeDiagnostic> get diagnostics => _diagnostics.stream;

  @override
  Stream<RuntimeInitializationProgress> get initialization =>
      _initialization.stream;

  @override
  Stream<DevelopmentPluginChangeBatch> get developmentChanges =>
      _node.developmentChanges;

  @override
  List<RuntimeDiagnostic> get latestDiagnostics => <RuntimeDiagnostic>[
    ..._node.latestDiagnostics,
    ..._native.latestDiagnostics,
  ];

  @override
  int get debugProcessStartCount =>
      _node.debugProcessStartCount + _native.debugProcessStartCount;

  @override
  Future<void> configureNodeEnvironmentProxy(bool enabled) =>
      _node.configureNodeEnvironmentProxy(enabled);

  @override
  Future<void> configurePluginHttpProxy(Uri? proxyUri) async {
    await _node.configurePluginHttpProxy(proxyUri);
    await _native.configurePluginHttpProxy(proxyUri);
  }

  @override
  Future<void> dispose() async {
    await Future.wait(<Future<void>>[_node.dispose(), _native.dispose()]);
    for (final subscription in _diagnosticSubscriptions) {
      await subscription.cancel();
    }
    for (final subscription in _initializationSubscriptions) {
      await subscription.cancel();
    }
    await _diagnostics.close();
    await _initialization.close();
  }
}
