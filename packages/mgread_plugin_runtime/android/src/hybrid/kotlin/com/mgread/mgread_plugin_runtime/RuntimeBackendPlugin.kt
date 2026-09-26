package com.mgread.mgread_plugin_runtime

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding

/** Registers the Node and native channels in one Flutter engine. */
class RuntimeBackendPlugin : FlutterPlugin, ActivityAware {
    private val node = JavetRuntimeBackendPlugin()
    private val native = NativeRuntimeBackendPlugin()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        node.onAttachedToEngine(binding)
        native.onAttachedToEngine(binding)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        native.onDetachedFromEngine(binding)
        node.onDetachedFromEngine(binding)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        node.onAttachedToActivity(binding)
        native.onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        native.onDetachedFromActivityForConfigChanges()
        node.onDetachedFromActivityForConfigChanges()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        node.onReattachedToActivityForConfigChanges(binding)
        native.onReattachedToActivityForConfigChanges(binding)
    }

    override fun onDetachedFromActivity() {
        native.onDetachedFromActivity()
        node.onDetachedFromActivity()
    }
}
