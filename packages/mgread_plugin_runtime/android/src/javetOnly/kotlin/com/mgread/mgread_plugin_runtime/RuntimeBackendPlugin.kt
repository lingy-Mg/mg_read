package com.mgread.mgread_plugin_runtime

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware

/** Node-only acceptance variant; normal Android builds use the hybrid bridge. */
class RuntimeBackendPlugin private constructor(backend: JavetRuntimeBackendPlugin) :
    FlutterPlugin by backend, ActivityAware by backend {
    constructor() : this(JavetRuntimeBackendPlugin())
}
