package com.example.novel_reader_ui

import android.app.Activity
import android.os.Build
import android.util.Log
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Native system support for the novel reader. */
class NovelReaderUiPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private var activity: Activity? = null
    private var keepScreenOn = false
    private var immersiveMode = false
    private var originalStatusBarsVisible: Boolean? = null
    private var originalNavigationBarsVisible: Boolean? = null
    private var originalSystemUiVisibility: Int? = null
    private var keepScreenOnActivity: Activity? = null
    private var keepScreenOnAddedByPlugin = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "novel_reader_ui/system")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getCapabilities" -> result.success(mapOf("keepScreenOn" to true, "immersiveMode" to true))
            "setReaderSystemUi" -> {
                val args = call.arguments as? Map<*, *> ?: run { result.error("invalid_argument", "A settings map is required.", null); return }
                val enabled = args["keepScreenOn"] as? Boolean ?: run { result.error("invalid_argument", "A keepScreenOn boolean is required.", null); return }
                val immersive = args["immersiveMode"] as? Boolean ?: run { result.error("invalid_argument", "An immersiveMode boolean is required.", null); return }
                val currentActivity = activity
                if ((enabled || immersive) && currentActivity == null) {
                    result.error("activity_unavailable", "No Android Activity is attached.", null)
                    return
                }
                updateReaderSystemUi(
                    target = currentActivity,
                    enabled = enabled,
                    immersive = immersive,
                    result = result,
                    commitRequestedState = true,
                )
            }
            else -> result.notImplemented()
        }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        updateReaderSystemUi(activity, keepScreenOn, immersiveMode)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        updateReaderSystemUi(activity, false, false)
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        updateReaderSystemUi(activity, keepScreenOn, immersiveMode)
    }

    override fun onDetachedFromActivity() {
        updateReaderSystemUi(activity, false, false)
        activity = null
        keepScreenOn = false
        immersiveMode = false
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        updateReaderSystemUi(activity, false, false)
        activity = null
        keepScreenOn = false
        immersiveMode = false
        channel.setMethodCallHandler(null)
    }

    private fun updateReaderSystemUi(
        target: Activity?,
        enabled: Boolean,
        immersive: Boolean,
        result: MethodChannel.Result? = null,
        commitRequestedState: Boolean = false,
    ) {
        if (target == null) {
            if (enabled || immersive) {
                result?.error("activity_unavailable", "No Android Activity is attached.", null)
            } else {
                if (commitRequestedState) {
                    keepScreenOn = false
                    immersiveMode = false
                }
                result?.success(null)
            }
            return
        }
        val previousKeepScreenOn = keepScreenOn
        val previousImmersiveMode = immersiveMode
        try {
            target.runOnUiThread {
                try {
                    applyKeepScreenOn(target, enabled)
                    applyImmersiveMode(target, immersive)
                    if (commitRequestedState) {
                        keepScreenOn = enabled
                        immersiveMode = immersive
                    }
                    result?.success(null)
                } catch (error: Exception) {
                    if (commitRequestedState) {
                        try {
                            applyKeepScreenOn(target, previousKeepScreenOn)
                            applyImmersiveMode(target, previousImmersiveMode)
                        } catch (rollbackError: Exception) {
                            Log.e(TAG, "Failed to restore reader window state", rollbackError)
                        }
                    }
                    reportWindowError(result, error)
                }
            }
        } catch (error: Exception) {
            reportWindowError(result, error)
        }
    }

    private fun applyKeepScreenOn(target: Activity, enabled: Boolean) {
        if (enabled) {
            if (keepScreenOnActivity !== target) {
                keepScreenOnActivity = target
                keepScreenOnAddedByPlugin = false
            }
            val alreadyEnabled =
                (target.window.attributes.flags and
                    WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) != 0
            if (!alreadyEnabled) {
                target.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                keepScreenOnAddedByPlugin = true
            }
            return
        }
        if (keepScreenOnActivity === target && keepScreenOnAddedByPlugin) {
            target.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
        if (keepScreenOnActivity === target) {
            keepScreenOnActivity = null
            keepScreenOnAddedByPlugin = false
        }
    }

    private fun applyImmersiveMode(target: Activity, enabled: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            target.window.insetsController?.let { controller ->
                if (enabled) {
                    if (originalStatusBarsVisible == null) {
                        val insets = target.window.decorView.rootWindowInsets
                        originalStatusBarsVisible =
                            insets?.isVisible(WindowInsets.Type.statusBars()) ?: true
                        originalNavigationBarsVisible =
                            insets?.isVisible(WindowInsets.Type.navigationBars()) ?: true
                    }
                    controller.systemBarsBehavior =
                        WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                    controller.hide(WindowInsets.Type.systemBars())
                } else {
                    restoreImmersiveMode(controller)
                }
            }
        } else {
            @Suppress("DEPRECATION")
            if (enabled) {
                if (originalSystemUiVisibility == null) {
                    originalSystemUiVisibility = target.window.decorView.systemUiVisibility
                }
                target.window.decorView.systemUiVisibility =
                    View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                    View.SYSTEM_UI_FLAG_FULLSCREEN or
                    View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                    View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                    View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
            } else if (originalSystemUiVisibility != null) {
                target.window.decorView.systemUiVisibility = originalSystemUiVisibility!!
                originalSystemUiVisibility = null
            }
        }
    }

    private fun restoreImmersiveMode(controller: WindowInsetsController) {
        when (originalStatusBarsVisible) {
            true -> controller.show(WindowInsets.Type.statusBars())
            false -> controller.hide(WindowInsets.Type.statusBars())
            null -> Unit
        }
        when (originalNavigationBarsVisible) {
            true -> controller.show(WindowInsets.Type.navigationBars())
            false -> controller.hide(WindowInsets.Type.navigationBars())
            null -> Unit
        }
        originalStatusBarsVisible = null
        originalNavigationBarsVisible = null
    }

    private fun reportWindowError(result: MethodChannel.Result?, error: Exception) {
        if (result != null) {
            result.error(
                "system_error",
                "Unable to update reader system UI.",
                error.message,
            )
        } else {
            Log.e(TAG, "Unable to update reader system UI", error)
        }
    }

    private companion object {
        const val TAG = "NovelReaderUiPlugin"
    }
}
