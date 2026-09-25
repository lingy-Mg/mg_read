/**
 * Stable Flutter registration entry point, present in the conventional main path.
 *
 * Gradle selects one RuntimeBackendPlugin implementation from the backend flavor.
 * The same delegate receives engine and Activity events; it owns all resources.
 */
package com.mgread.mgread_plugin_runtime

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware

class MgReadPluginRuntimePlugin private constructor(
    backend: RuntimeBackendPlugin,
) : FlutterPlugin by backend, ActivityAware by backend {
    constructor() : this(RuntimeBackendPlugin())
}
