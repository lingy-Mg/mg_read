package com.mgread.mg_read

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Process-lifetime Android signals for the active Flutter audio session. */
class AudioBackgroundPlatformBridge :
    FlutterPlugin,
    MethodChannel.MethodCallHandler {
    private lateinit var applicationContext: Context
    private lateinit var channel: MethodChannel
    private var receiverRegistered = false
    private var toneGenerator: ToneGenerator? = null

    private val screenOnReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == Intent.ACTION_SCREEN_ON) {
                channel.invokeMethod("screenTurnedOn", null)
            }
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
        val filter = IntentFilter(Intent.ACTION_SCREEN_ON)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            applicationContext.registerReceiver(
                screenOnReceiver,
                filter,
                Context.RECEIVER_NOT_EXPORTED,
            )
        } else {
            @Suppress("DEPRECATION")
            applicationContext.registerReceiver(screenOnReceiver, filter)
        }
        receiverRegistered = true
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "playCommandTone" -> result.success(playCommandTone())
            else -> result.notImplemented()
        }
    }

    private fun playCommandTone(): Boolean {
        return try {
            val generator = toneGenerator ?: ToneGenerator(
                AudioManager.STREAM_MUSIC,
                COMMAND_TONE_VOLUME,
            ).also { toneGenerator = it }
            generator.startTone(ToneGenerator.TONE_PROP_ACK, COMMAND_TONE_DURATION_MS)
        } catch (_: RuntimeException) {
            toneGenerator?.release()
            toneGenerator = null
            false
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        if (receiverRegistered) {
            applicationContext.unregisterReceiver(screenOnReceiver)
            receiverRegistered = false
        }
        toneGenerator?.release()
        toneGenerator = null
    }

    private companion object {
        const val CHANNEL = "mgread/audio_background"
        const val COMMAND_TONE_VOLUME = 65
        const val COMMAND_TONE_DURATION_MS = 110
    }
}
