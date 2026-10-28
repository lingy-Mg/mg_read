package com.mgread.mgread_plugin_runtime

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Proxy
import android.os.Build
import io.flutter.plugin.common.EventChannel

/** Emits the current route on subscription and system proxy changes (including VPN removal).
 * The Flutter engine owns registration; it never starts either Runtime backend.
 */
internal class AndroidSystemProxyObserver(
    private val context: Context,
    private val readEnvironment: () -> Map<String, String>,
) : EventChannel.StreamHandler {
    private var sink: EventChannel.EventSink? = null
    private var registered = false
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == Proxy.PROXY_CHANGE_ACTION) sink?.success(readEnvironment())
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        dispose()
        sink = events
        val filter = IntentFilter(Proxy.PROXY_CHANGE_ACTION)
        if (Build.VERSION.SDK_INT >= 33) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(receiver, filter)
        }
        registered = true
        sink?.success(readEnvironment())
    }

    override fun onCancel(arguments: Any?) = dispose()

    fun dispose() {
        sink = null
        if (registered) context.unregisterReceiver(receiver)
        registered = false
    }
}
