package com.mgread.mgread_plugin_runtime

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel

/** Flutter bridge for the Runtime-owned Android Javet adapter. */
class MgReadPluginRuntimePlugin : FlutterPlugin, MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var progressChannel: EventChannel? = null
    private var progressSink: EventChannel.EventSink? = null
    private var runtime: AndroidRuntimeHost? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val context = binding.applicationContext
        val assetRoot = binding.flutterAssets.getAssetFilePathByName(
            "packages/mgread_plugin_runtime/assets/runtime/android",
        )
        runtime = AndroidRuntimeHost(context, assetRoot) { progress ->
            mainHandler.post {
                progressSink?.success(
                    mapOf(
                        "completedBytes" to progress.completedBytes,
                        "stage" to progress.stage,
                        "totalBytes" to progress.totalBytes,
                    ),
                )
            }
        }
        channel = MethodChannel(
            binding.binaryMessenger,
            "mgread_plugin_runtime/android",
        ).also { it.setMethodCallHandler(this) }
        progressChannel = EventChannel(
            binding.binaryMessenger,
            "mgread_plugin_runtime/android/progress",
        ).also { it.setStreamHandler(this) }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val host = runtime
        if (host == null) {
            result.error("runtime_unavailable", "Android Runtime is not attached.", null)
            return
        }
        when (call.method) {
            "invoke" -> {
                val method = call.argument<String>("method")
                val params = call.argument<Map<String, Any?>>("params") ?: emptyMap()
                val deadline = call.argument<Long>("deadlineUnixMs") ?: 0L
                if (method.isNullOrBlank() || deadline <= 0L) {
                    result.error("invalid_request", "Android Runtime request is invalid.", null)
                    return
                }
                host.invoke(method, params, deadline) { error, value ->
                    mainHandler.post {
                        if (error == null) {
                            result.success(value)
                        } else {
                            result.error(error.code, error.message, null)
                        }
                    }
                }
            }
            "dispose" -> {
                host.dispose()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        progressChannel?.setStreamHandler(null)
        progressChannel = null
        progressSink = null
        runtime?.dispose()
        runtime = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        progressSink = events
    }

    override fun onCancel(arguments: Any?) {
        progressSink = null
    }
}
