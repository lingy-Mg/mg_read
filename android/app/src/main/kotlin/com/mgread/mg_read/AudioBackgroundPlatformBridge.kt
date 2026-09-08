package com.mgread.mg_read

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioManager
import android.media.ToneGenerator
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Process-lifetime screen/network signals and command tones for Flutter audio.
 * Receivers/callbacks are engine-owned and released on engine detach.
 */
class AudioBackgroundPlatformBridge :
    FlutterPlugin,
    MethodChannel.MethodCallHandler {
    private lateinit var applicationContext: Context
    private lateinit var channel: MethodChannel
    private var receiverRegistered = false
    private var networkCallbackRegistered = false
    private var toneGenerator: ToneGenerator? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var usableNetwork: Network? = null

    private val screenOnReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == Intent.ACTION_SCREEN_ON) {
                channel.invokeMethod("screenTurnedOn", null)
            }
        }
    }

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
            val usable = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
            if (!usable || usableNetwork == network) return
            usableNetwork = network
            mainHandler.post { channel.invokeMethod("networkAvailable", null) }
        }

        override fun onLost(network: Network) {
            if (usableNetwork == network) usableNetwork = null
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
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            val connectivity = applicationContext.getSystemService(
                Context.CONNECTIVITY_SERVICE,
            ) as ConnectivityManager
            try {
                connectivity.registerDefaultNetworkCallback(networkCallback)
                networkCallbackRegistered = true
            } catch (_: RuntimeException) {
                // Screen-on and foreground recovery remain available if the
                // platform refuses another process-level callback.
            }
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "playCommandTone" -> result.success(
                playCommandTone(call.argument<String>("kind")),
            )
            else -> result.notImplemented()
        }
    }

    private fun playCommandTone(kind: String?): Boolean {
        return try {
            val generator = toneGenerator ?: ToneGenerator(
                AudioManager.STREAM_MUSIC,
                COMMAND_TONE_VOLUME,
            ).also { toneGenerator = it }
            val tone = when (kind) {
                "boundary" -> ToneGenerator.TONE_PROP_NACK
                "failed" -> ToneGenerator.TONE_SUP_ERROR
                else -> ToneGenerator.TONE_PROP_ACK
            }
            generator.startTone(tone, COMMAND_TONE_DURATION_MS)
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
        if (networkCallbackRegistered) {
            val connectivity = applicationContext.getSystemService(
                Context.CONNECTIVITY_SERVICE,
            ) as ConnectivityManager
            try {
                connectivity.unregisterNetworkCallback(networkCallback)
            } catch (_: RuntimeException) {
                // Detach is idempotent even if Android already removed it.
            }
            networkCallbackRegistered = false
            usableNetwork = null
        }
        mainHandler.removeCallbacksAndMessages(null)
        toneGenerator?.release()
        toneGenerator = null
    }

    private companion object {
        const val CHANNEL = "mgread/audio_background"
        const val COMMAND_TONE_VOLUME = 65
        const val COMMAND_TONE_DURATION_MS = 110
    }
}
