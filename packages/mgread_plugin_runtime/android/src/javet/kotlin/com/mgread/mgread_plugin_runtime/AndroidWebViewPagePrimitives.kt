/** Host-only UI and native input primitives shared by the Android page host. */
package com.mgread.mgread_plugin_runtime

import android.net.Uri
import android.view.KeyEvent
import android.view.View
import android.webkit.GeolocationPermissions
import android.webkit.JsPromptResult
import android.webkit.JsResult
import android.webkit.PermissionRequest
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebView
import org.json.JSONObject

internal fun androidBlockingChromeClient(): WebChromeClient = object : WebChromeClient() {
    override fun onJsAlert(view: WebView?, url: String?, message: String?, result: JsResult?): Boolean {
        result?.cancel(); return true
    }
    override fun onJsConfirm(view: WebView?, url: String?, message: String?, result: JsResult?): Boolean {
        result?.cancel(); return true
    }
    override fun onJsPrompt(view: WebView?, url: String?, message: String?, defaultValue: String?, result: JsPromptResult?): Boolean {
        result?.cancel(); return true
    }
    override fun onPermissionRequest(request: PermissionRequest?) { request?.deny() }
    override fun onGeolocationPermissionsShowPrompt(origin: String?, callback: GeolocationPermissions.Callback?) {
        callback?.invoke(origin, false, false)
    }
    override fun onShowFileChooser(webView: WebView?, filePathCallback: ValueCallback<Array<Uri>>?, fileChooserParams: FileChooserParams?): Boolean {
        filePathCallback?.onReceiveValue(null); return true
    }
    override fun onCreateWindow(view: WebView?, isDialog: Boolean, isUserGesture: Boolean, resultMsg: android.os.Message?): Boolean = false
    override fun onShowCustomView(view: View?, callback: CustomViewCallback?) { callback?.onCustomViewHidden() }
}

internal fun androidPageFetchBody(value: JSONObject): String {
    val headers = value.getJSONObject("headers").toString()
    val body = if (value.isNull("body")) "null" else JSONObject.quote(value.getString("body"))
    val readBody = when (value.getString("responseType")) {
        "json" -> "await response.json()"
        "base64" -> "btoa(Array.from(new Uint8Array(await response.arrayBuffer()),b=>String.fromCharCode(b)).join(''))"
        else -> "await response.text()"
    }
    return """
        const response=await fetch(${JSONObject.quote(value.getString("url"))},{
          method:${JSONObject.quote(value.getString("method"))},
          headers:JSON.parse(${JSONObject.quote(headers)}),body:$body,
          credentials:'include',redirect:'follow'
        });
        const headers={}; response.headers.forEach((v,k)=>headers[k]=v);
        const responseBody=$readBody;
        return {status:response.status,url:response.url,headers,body:responseBody};
    """.trimIndent()
}

internal fun androidStartPageAsyncScript(jobId: String, body: String): String {
    val key = androidQuoteJavaScriptString(jobId)
    return """
        (() => {
          globalThis.__mgreadPageResults ??= Object.create(null);
          globalThis.__mgreadPageJobs ??= Object.create(null);
          const key = $key;
          const token = {};
          globalThis.__mgreadPageJobs[key] = token;
          (async () => {
            let json;
            try {
              const response = await (async () => { $body })();
              json = JSON.stringify({ok:true,response});
              if (json === undefined) throw new Error('not_json');
            } catch (_) {
              json = JSON.stringify({ok:false,code:'plugin_execution_failed'});
            }
            if (globalThis.__mgreadPageJobs?.[key] === token) {
              globalThis.__mgreadPageResults[key] = json;
            }
          })();
          return true;
        })()
    """.trimIndent()
}

internal fun androidPollPageAsyncScript(jobId: String): String {
    val key = androidQuoteJavaScriptString(jobId)
    return "(() => {const r=globalThis.__mgreadPageResults?.[$key];" +
        "if(r===undefined)return null;delete globalThis.__mgreadPageResults[$key];" +
        "delete globalThis.__mgreadPageJobs?.[$key];return r;})()"
}

internal fun androidExpirePageAsyncScript(jobId: String): String {
    val key = androidQuoteJavaScriptString(jobId)
    return "(() => {delete globalThis.__mgreadPageJobs?.[$key];" +
        "delete globalThis.__mgreadPageResults?.[$key];return true;})()"
}

private fun androidQuoteJavaScriptString(value: String): String = buildString(value.length + 2) {
    append('"')
    value.forEach { character ->
        when (character) {
            '"' -> append("\\\"")
            '\\' -> append("\\\\")
            '\b' -> append("\\b")
            '\u000C' -> append("\\f")
            '\n' -> append("\\n")
            '\r' -> append("\\r")
            '\t' -> append("\\t")
            else -> if (character.code < 0x20) {
                append("\\u")
                append(character.code.toString(16).padStart(4, '0'))
            } else {
                append(character)
            }
        }
    }
    append('"')
}

internal fun androidDispatchNativeKey(webView: WebView, value: JSONObject): Boolean {
    val code = androidKeyCode(value.getString("key")) ?: return false
    var meta = 0
    val modifiers = value.getJSONArray("modifiers")
    repeat(modifiers.length()) {
        meta = meta or when (modifiers.getString(it)) {
            "alt" -> KeyEvent.META_ALT_ON
            "control" -> KeyEvent.META_CTRL_ON
            "shift" -> KeyEvent.META_SHIFT_ON
            else -> 0
        }
    }
    val now = android.os.SystemClock.uptimeMillis()
    val down = KeyEvent(now, now, KeyEvent.ACTION_DOWN, code, 0, meta)
    val up = KeyEvent(now, now + 16L, KeyEvent.ACTION_UP, code, 0, meta)
    return webView.requestFocus(View.FOCUS_DOWN) && webView.dispatchKeyEvent(down) && webView.dispatchKeyEvent(up)
}

private fun androidKeyCode(key: String): Int? = when (key) {
    "Enter" -> KeyEvent.KEYCODE_ENTER
    "Tab" -> KeyEvent.KEYCODE_TAB
    "Escape" -> KeyEvent.KEYCODE_ESCAPE
    "ArrowUp" -> KeyEvent.KEYCODE_DPAD_UP
    "ArrowDown" -> KeyEvent.KEYCODE_DPAD_DOWN
    "ArrowLeft" -> KeyEvent.KEYCODE_DPAD_LEFT
    "ArrowRight" -> KeyEvent.KEYCODE_DPAD_RIGHT
    "PageUp" -> KeyEvent.KEYCODE_PAGE_UP
    "PageDown" -> KeyEvent.KEYCODE_PAGE_DOWN
    "Home" -> KeyEvent.KEYCODE_MOVE_HOME
    "End" -> KeyEvent.KEYCODE_MOVE_END
    "Backspace" -> KeyEvent.KEYCODE_DEL
    "Delete" -> KeyEvent.KEYCODE_FORWARD_DEL
    else -> null
}

internal fun androidPageActionLabel(operation: String): String = when (operation) {
    "page.navigate" -> "正在导航"
    "page.evaluate" -> "正在执行脚本"
    "page.html" -> "正在获取 HTML"
    "page.fetch" -> "正在发送请求"
    "page.click" -> "正在点击页面"
    "page.input" -> "正在输入文本"
    "page.key" -> "正在发送按键"
    "page.waitText" -> "正在等待页面内容"
    "page.getUrl" -> "正在读取地址"
    else -> "正在探测"
}
