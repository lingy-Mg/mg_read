/**
 * Android WebView owner for browser.session.v1 and ctx.webview.
 *
 * One plugin ID owns at most one resident WebView. When the installed WebView
 * supports multi-profile, that WebView receives an isolated profile; older
 * WebViews use the app's single default WebView profile and emit an explicit
 * fallback warning. Hidden sessions never attach a View; visible verification
 * uses one global foreground dialog. Debug sessions stay pinned: hide and
 * window-close gestures only hide the dialog and preserve the WebView.
 * Supporting JavaScript is host-authored; ctx.webview's explicit script body is
 * JSON encoded into a revocable async wrapper and returns only JSON values.
 * Timeout and cancellation delete both the job token and any completed result.
 */
package com.mgread.mgread_plugin_runtime

import android.app.Activity
import android.app.Dialog
import android.content.Context
import android.content.MutableContextWrapper
import android.graphics.Color
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Gravity
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.webkit.CookieManager
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.webkit.NavigationParameters
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import org.json.JSONObject
import org.json.JSONTokener
import java.net.HttpURLConnection
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

private enum class ProfileMode {
    ISOLATED,
    SINGLE_FALLBACK,
}

internal class AndroidBrowserSessionHost(private val context: Context) {
    private data class Job(
        val cancelled: AtomicBoolean,
        val deadlineUnixMs: Long,
        var hadChallenge: Boolean,
        val id: String,
        val request: AndroidBrowserSessionRequest,
        var retries: Int = 0,
        @Volatile var connection: HttpURLConnection? = null,
    )

    private data class Session(
        val contextWrapper: MutableContextWrapper,
        val cookieManager: CookieManager,
        val pluginId: String,
        var pluginName: String,
        val profileMode: ProfileMode,
        val verifiedAt: MutableMap<String, Long>,
        val webView: WebView,
        var activeJobId: String? = null,
        var lastUsedAt: Long = System.currentTimeMillis(),
        var statusView: TextView? = null,
        var urlView: TextView? = null,
    )

    private val mainHandler = Handler(Looper.getMainLooper())
    private val network = Executors.newFixedThreadPool(2) { runnable ->
        Thread(runnable, "mgread-browser-http").apply { isDaemon = true }
    }
    private val completed = ConcurrentHashMap<String, String>()
    private val jobs = ConcurrentHashMap<String, Job>()
    private val sessions = mutableMapOf<String, Session>()
    private val debugPinnedPlugins = mutableSetOf<String>()
    private val disposed = AtomicBoolean(false)
    private var activity: Activity? = null
    private var foregroundDialog: Dialog? = null
    private var foregroundPluginId: String? = null

    fun attachActivity(value: Activity?) {
        mainHandler.post {
            activity = value
            if (value == null) hideForeground()
        }
    }

    fun start(raw: String): String {
        val id = UUID.randomUUID().toString()
        if (disposed.get()) {
            completed[id] = errorResult("unsupported")
            return id
        }
        val request = runCatching { AndroidBrowserSessionRequest.parse(raw) }.getOrElse {
            completed[id] = errorResult("plugin_execution_failed")
            return id
        }
        Log.i(TAG, "browser_session_start transport=${request.transport} presentation=${request.presentation}")
        if (jobs.size >= MAX_PENDING_REQUESTS) {
            completed[id] = errorResult("overloaded")
            return id
        }
        val job = Job(
            cancelled = AtomicBoolean(false),
            deadlineUnixMs = System.currentTimeMillis() + request.timeoutMs,
            hadChallenge = false,
            id = id,
            request = request,
        )
        jobs[id] = job
        mainHandler.post { begin(job) }
        mainHandler.postDelayed({
            if (isCurrent(job) && System.currentTimeMillis() >= job.deadlineUnixMs) {
                completeError(job, "timeout")
            }
        }, request.timeoutMs)
        return id
    }

    /**
     * Polls from the Javet thread without relying on the embedded Node timer
     * queue. The WebView callbacks still run on the Android main thread, so a
     * short wait here does not block page loading or the visible verification
     * surface. The wait is bounded to keep the private bridge responsive.
     */
    fun poll(id: String, waitMillis: Long = 0L): String {
        val deadline = System.nanoTime() + waitMillis.coerceIn(0L, MAX_POLL_WAIT_MILLIS) * 1_000_000L
        do {
            completed.remove(id)?.let {
                Log.i(TAG, "browser_session_poll_complete")
                return it
            }
            if (System.nanoTime() >= deadline) return PENDING_RESULT
            try {
                Thread.sleep(POLL_SLEEP_MILLIS)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                return PENDING_RESULT
            }
        } while (true)
    }

    fun cancel(id: String) {
        jobs[id]?.let { job ->
            job.cancelled.set(true)
            job.connection?.disconnect()
            mainHandler.post { completeError(job, "cancelled") }
        }
    }

    fun dispose() {
        if (!disposed.compareAndSet(false, true)) return
        jobs.values.forEach { it.cancelled.set(true); it.connection?.disconnect() }
        network.shutdownNow()
        mainHandler.post {
            jobs.values.toList().forEach { completeError(it, "cancelled") }
            hideForeground()
            sessions.values.forEach { session ->
                (session.webView.parent as? ViewGroup)?.removeView(session.webView)
                session.webView.stopLoading()
                session.webView.destroy()
            }
            sessions.clear()
        }
    }

    private fun begin(job: Job) {
        if (!isCurrent(job)) return
        Log.i(TAG, "browser_session_begin transport=${job.request.transport}")
        if (job.request.operation == "page.close") {
            sessions[job.request.pluginId]?.let { session ->
                val activeJob = session.activeJobId?.let { jobs[it] }
                closePage(session)
                activeJob?.let { completeError(it, "cancelled") }
            }
            completePageSuccess(job, JSONObject())
            return
        }
        if (job.request.operation == "page.show" || job.request.operation == "page.hide") {
            val existing = sessions[job.request.pluginId]
            if (existing == null) {
                completeError(job, "unsupported")
            } else if (job.request.operation == "page.show") {
                updateStatus(existing, "已显示")
                if (showForeground(existing, job)) completePageSuccess(job, JSONObject())
                else completeError(job, "interaction_required")
            } else {
                if (existing.pluginId !in debugPinnedPlugins && foregroundPluginId == existing.pluginId) hideForeground()
                completePageSuccess(job, JSONObject())
            }
            return
        }
        val profileMode = if (WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)) {
            Log.i(TAG, "browser_session_profile_mode=isolated plugin_id=${job.request.pluginId}")
            ProfileMode.ISOLATED
        } else {
            Log.w(
                TAG,
                "browser_session_profile_mode=single_fallback " +
                    "reason=multi_profile_unsupported " +
                    "plugin_id=${job.request.pluginId} cookie_scope=app_default_webview",
            )
            ProfileMode.SINGLE_FALLBACK
        }
        val session = runCatching { sessionFor(job, profileMode) }.getOrElse {
            completeError(job, "unsupported")
            return
        } ?: return
        if (session.profileMode != profileMode) {
            Log.w(
                TAG,
                "browser_session_profile_mode_changed " +
                    "plugin_id=${job.request.pluginId} expected=$profileMode actual=${session.profileMode}",
            )
            completeError(job, "unsupported")
            return
        }
        if (job.request.operation == "debug") {
            beginDebug(job, session)
            return
        }
        if (job.request.operation.startsWith("page.")) {
            beginPage(job, session)
            return
        }
        if (session.activeJobId != null) {
            completeError(job, "overloaded")
            return
        }
        session.activeJobId = job.id
        session.lastUsedAt = System.currentTimeMillis()
        val verified = session.verifiedAt[job.request.origin]
            ?.let { System.currentTimeMillis() - it <= VERIFICATION_CACHE_MILLIS } == true
        val sameOrigin = runCatching { originOf(session.webView.url.orEmpty()) }
            .getOrNull() == job.request.origin
        if (verified && (job.request.transport == "http" || sameOrigin)) {
            perform(job, session, verificationState = "verified")
        } else {
            if (job.request.presentation == "visible" && !showForeground(session, job)) {
                completeError(job, "interaction_required")
                return
            }
            loadForVerification(job, session)
        }
    }

    private fun sessionFor(job: Job, profileMode: ProfileMode): Session? {
        sessions[job.request.pluginId]?.let {
            it.pluginName = job.request.pluginName
            Log.i(TAG, "browser_session_reuse plugin_id=${job.request.pluginId}")
            return it
        }
        if (sessions.size >= MAX_RESIDENT_WEBVIEWS) {
            val evicted = sessions.values
                .filter { it.activeJobId == null }
                .minByOrNull { it.lastUsedAt }
            if (evicted == null) {
                completeError(job, "overloaded")
                return null
            }
            (evicted.webView.parent as? ViewGroup)?.removeView(evicted.webView)
            evicted.webView.destroy()
            sessions.remove(evicted.pluginId)
        }
        val wrapper = MutableContextWrapper(activity ?: context)
        val webView = WebView(wrapper)
        if (profileMode == ProfileMode.ISOLATED) {
            WebViewCompat.setProfile(webView, profileName(job.request.pluginId))
        }
        configure(webView)
        val session = Session(
            contextWrapper = wrapper,
            cookieManager = if (profileMode == ProfileMode.ISOLATED) {
                WebViewCompat.getProfile(webView).cookieManager
            } else {
                CookieManager.getInstance()
            },
            pluginId = job.request.pluginId,
            pluginName = job.request.pluginName,
            profileMode = profileMode,
            verifiedAt = mutableMapOf(),
            webView = webView,
        )
        webView.webViewClient = clientFor(session)
        webView.webChromeClient = androidBlockingChromeClient()
        session.cookieManager.setAcceptCookie(true)
        session.cookieManager.setAcceptThirdPartyCookies(webView, true)
        sessions[job.request.pluginId] = session
        return session
    }

    private fun configure(webView: WebView) {
        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            javaScriptCanOpenWindowsAutomatically = false
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            setSupportMultipleWindows(false)
            mediaPlaybackRequiresUserGesture = true
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) safeBrowsingEnabled = true
        }
        webView.isHorizontalScrollBarEnabled = false
        webView.setDownloadListener { _, _, _, _, _ ->
            Log.i(TAG, "browser_download_blocked")
        }
    }

    private fun clientFor(session: Session): WebViewClient = object : WebViewClient() {
        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
            if (session.activeJobId?.let { jobs[it] }?.request?.operation?.startsWith("page.") == true) {
                return request.url.scheme != "https" && request.url.scheme != "http"
            }
            val job = session.activeJobId?.let { jobs[it] } ?: return request.url.scheme != "https" && request.url.scheme != "http"
            return runCatching { originOf(request.url.toString()) != job.request.origin }
                .getOrDefault(true)
        }

        override fun onPageFinished(view: WebView, url: String) {
            session.urlView?.text = url
        }

        override fun onReceivedError(
            view: WebView,
            request: WebResourceRequest,
            error: WebResourceError,
        ) {
            if (!request.isForMainFrame) return
            session.activeJobId?.let { jobs[it] }?.let { completeError(it, "plugin_execution_failed") }
        }

        override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
            session.activeJobId?.let { jobs[it] }?.let { completeError(it, "plugin_execution_failed") }
            sessions.remove(session.pluginId)
            (view.parent as? ViewGroup)?.removeView(view)
            view.destroy()
            return true
        }
    }

    private fun beginPage(job: Job, session: Session) {
        val request = job.request
        if (request.operation == "page.open") {
            val visible = request.pageParams?.optBoolean("visible", false) == true || request.pluginId in debugPinnedPlugins
            if (visible && !showForeground(session, job)) {
                completeError(job, "interaction_required")
            } else {
                updateStatus(session, "已打开")
                completePageSuccess(job, JSONObject())
            }
            return
        }
        if (session.activeJobId != null) {
            completeError(job, "overloaded")
            return
        }
        session.activeJobId = job.id
        session.lastUsedAt = System.currentTimeMillis()
        updateStatus(session, androidPageActionLabel(request.operation))
        when (request.operation) {
            "page.navigate" -> {
                navigate(session.webView, request.url, emptyMap())
                pollPageReady(job, session)
            }
            "page.evaluate" -> startPageAsyncScript(
                job,
                session,
                "const AsyncFunction=Object.getPrototypeOf(async function(){}).constructor;" +
                    "const value=await new AsyncFunction(${JSONObject.quote(request.pageParams!!.getString("code"))}).call(window);" +
                    "return {value};",
            )
            "page.html" -> startPageAsyncScript(
                job,
                session,
                "return {html:document.documentElement?.outerHTML??''};",
            )
            "page.fetch" -> startPageAsyncScript(job, session, androidPageFetchBody(request.pageParams!!))
            "page.cdp" -> completeError(job, "unsupported")
            "page.click" -> performPageClick(job, session)
            "page.input" -> {
                if (!isPageVisible(session)) completeError(job, "interaction_required")
                else if (!commitNativeText(session.webView, request.pageParams!!.getString("text"))) {
                    completeError(job, "plugin_execution_failed")
                } else completePageSuccess(job, JSONObject())
            }
            "page.key" -> {
                if (!isPageVisible(session)) completeError(job, "interaction_required")
                else if (!androidDispatchNativeKey(session.webView, request.pageParams!!)) completeError(job, "plugin_execution_failed")
                else completePageSuccess(job, JSONObject())
            }
            "page.waitText" -> pollPageText(job, session)
            "page.getUrl" -> completePageSuccess(job, JSONObject().put("url", session.webView.url.orEmpty()))
            else -> completeError(job, "unsupported")
        }
    }

    private fun beginDebug(job: Job, session: Session) {
        val action = job.request.pageParams?.optString("action").orEmpty()
        if (action != "enter" && action != "show") { completeError(job, "plugin_execution_failed"); return }
        debugPinnedPlugins += job.request.pluginId
        updateStatus(session, if (action == "enter") "WebView 调试" else "已显示")
        if (!showForeground(session, job)) { completeError(job, "interaction_required"); return }
        completePageSuccess(job, JSONObject().put("accepted", true).put("action", action).put("version", 1))
    }

    private fun pollPageReady(job: Job, session: Session) {
        if (!isCurrent(job, session)) return
        if (System.currentTimeMillis() >= job.deadlineUnixMs) {
            completeError(job, "timeout")
            return
        }
        session.webView.evaluateJavascript("document.readyState") { raw ->
            if (!isCurrent(job, session)) return@evaluateJavascript
            val state = runCatching { JSONTokener(raw).nextValue() as? String }.getOrNull()
            if (state == "interactive" || state == "complete") {
                completePageSuccess(job, JSONObject())
            } else {
                mainHandler.postDelayed({ pollPageReady(job, session) }, PAGE_OPERATION_POLL_MILLIS)
            }
        }
    }

    private fun startPageAsyncScript(job: Job, session: Session, body: String) {
        session.webView.evaluateJavascript(androidStartPageAsyncScript(job.id, body)) {
            mainHandler.postDelayed({ pollPageAsyncScript(job, session) }, PAGE_OPERATION_POLL_MILLIS)
        }
    }

    private fun pollPageAsyncScript(job: Job, session: Session) {
        if (!isCurrent(job, session)) return
        if (System.currentTimeMillis() >= job.deadlineUnixMs) {
            completeError(job, "timeout")
            return
        }
        session.webView.evaluateJavascript(androidPollPageAsyncScript(job.id)) { raw ->
            if (!isCurrent(job, session)) return@evaluateJavascript
            val encoded = decodeEvaluation(raw)
            if (encoded == null) {
                mainHandler.postDelayed({ pollPageAsyncScript(job, session) }, PAGE_OPERATION_POLL_MILLIS)
                return@evaluateJavascript
            }
            val result = runCatching { JSONObject(encoded) }.getOrNull()
            if (result?.optBoolean("ok", false) != true) {
                completeError(job, result?.optString("code") ?: "plugin_execution_failed")
                return@evaluateJavascript
            }
            val response = result.optJSONObject("response")
            if (response == null) completeError(job, "plugin_execution_failed")
            else completePageSuccess(job, response)
        }
    }

    private fun pollPageText(job: Job, session: Session) {
        if (!isCurrent(job, session)) return
        if (System.currentTimeMillis() >= job.deadlineUnixMs) {
            completeError(job, "timeout")
            return
        }
        val value = job.request.pageParams!!
        val expression = if (value.getString("scope") == "html") {
            "document.documentElement?.outerHTML??''"
        } else {
            "document.documentElement?.innerText??''"
        }
        val script = "(() => ($expression).includes(${JSONObject.quote(value.getString("text"))}))()"
        session.webView.evaluateJavascript(script) { raw ->
            if (!isCurrent(job, session)) return@evaluateJavascript
            if (raw == "true") {
                completePageSuccess(job, JSONObject().put("url", session.webView.url.orEmpty()))
            } else {
                mainHandler.postDelayed({ pollPageText(job, session) }, PAGE_OPERATION_POLL_MILLIS)
            }
        }
    }

    private fun performPageClick(job: Job, session: Session) {
        if (!isPageVisible(session)) {
            completeError(job, "interaction_required")
            return
        }
        session.webView.evaluateJavascript("window.devicePixelRatio||1") { raw ->
            if (!isCurrent(job, session)) return@evaluateJavascript
            val ratio = raw?.toDoubleOrNull() ?: Double.NaN
            val value = job.request.pageParams!!
            if (!dispatchWebViewTap(session.webView, value.getDouble("x"), value.getDouble("y"), ratio)) {
                completeError(job, "plugin_execution_failed")
            } else completePageSuccess(job, JSONObject())
        }
    }

    private fun completePageSuccess(job: Job, response: JSONObject) {
        if (!isCurrent(job)) return
        completed[job.id] = JSONObject().put("state", "done").put("response", response).toString(); finish(job)
    }

    private fun isPageVisible(session: Session): Boolean = foregroundPluginId == session.pluginId && foregroundDialog?.isShowing == true && session.webView.isAttachedToWindow

    private fun updateStatus(session: Session, action: String) { session.statusView?.text = "${session.pluginName}正在进行探测 - $action"; session.urlView?.text = session.webView.url.orEmpty() }

    private fun loadForVerification(job: Job, session: Session) {
        if (!isCurrent(job, session)) return
        Log.i(TAG, "browser_session_load_for_verification")
        navigate(session.webView, job.request.url, job.request.headers)
        mainHandler.postDelayed({ probePage(job, session) }, PAGE_POLL_MILLIS)
    }

    private fun navigate(webView: WebView, url: String, headers: Map<String, String>) {
        val usedModernApi = runCatching {
            if (!WebViewFeature.isFeatureSupported(WebViewFeature.WEBVIEW_NAVIGATE_EXPERIMENTAL_V1)) {
                false
            } else {
                WebViewCompat.navigate(
                    webView,
                    url,
                    NavigationParameters.Builder()
                        .addAdditionalHeaders(headers)
                        .build(),
                )
                true
            }
        }.getOrElse {
            Log.w(TAG, "browser_session_navigation_api=webkit_navigate_failed_fallback")
            false
        }
        if (!usedModernApi) {
            Log.w(TAG, "browser_session_navigation_api=load_url_fallback reason=webkit_navigate_unsupported")
            webView.loadUrl(url, headers)
        } else {
            Log.i(TAG, "browser_session_navigation_api=webkit_navigate")
        }
    }

    private fun probePage(job: Job, session: Session) {
        if (!isCurrent(job, session)) return
        if (System.currentTimeMillis() >= job.deadlineUnixMs) {
            completeError(job, "timeout")
            return
        }
        session.webView.evaluateJavascript(PAGE_PROBE_SCRIPT) { raw ->
            if (!isCurrent(job, session)) return@evaluateJavascript
            val value = decodeEvaluation(raw)?.let { runCatching { JSONObject(it) }.getOrNull() }
            val ready = value?.optBoolean("ready", false) == true
            val href = value?.optString("href").orEmpty()
            val challenge = value?.optBoolean("challenge", false) == true
            val sameOrigin = runCatching { originOf(href) == job.request.origin }.getOrDefault(false)
            Log.i(TAG, "browser_session_probe ready=$ready challenge=$challenge same_origin=$sameOrigin")
            if (ready && sameOrigin && !challenge) {
                session.verifiedAt[job.request.origin] = System.currentTimeMillis()
                Log.i(
                    TAG,
                    "browser_session_manual_verification_success " +
                        "plugin_id=${job.request.pluginId} had_challenge=${job.hadChallenge}",
                )
                perform(job, session, if (job.hadChallenge) "verified" else "not-required")
                return@evaluateJavascript
            }
            if (challenge) {
                job.hadChallenge = true
                val elapsed = job.request.timeoutMs - (job.deadlineUnixMs - System.currentTimeMillis())
                if (elapsed >= INTERACTION_GRACE_MILLIS) {
                    if (job.request.interaction == "silent" ||
                        job.request.presentation == "hidden"
                    ) {
                        completeError(job, "interaction_required")
                        return@evaluateJavascript
                    }
                }
            }
            mainHandler.postDelayed({ probePage(job, session) }, PAGE_POLL_MILLIS)
        }
    }

    private fun perform(job: Job, session: Session, verificationState: String) {
        Log.i(TAG, "browser_session_perform transport=${job.request.transport}")
        if (job.request.operation == "interaction") {
            performInteraction(job, session)
        } else if (job.request.transport == "webview") {
            performWebViewFetch(job, session, verificationState)
        } else if (job.request.transport == "html") {
            performPageHtml(job, session, verificationState)
        } else {
            performHttp(job, session, verificationState)
        }
    }

    private fun performInteraction(job: Job, session: Session) {
        if (!isCurrent(job, session)) return
        session.webView.evaluateJavascript(interactionTargetScript(job.request)) { raw ->
            if (!isCurrent(job, session)) return@evaluateJavascript
            val response = decodeEvaluation(raw)?.let { runCatching { JSONObject(it) }.getOrNull() }
            if (response?.optBoolean("accepted", false) != true ||
                response.optString("action") != job.request.action
            ) {
                completeError(job, "plugin_execution_failed")
                return@evaluateJavascript
            }
            if (job.request.action != "coordinates") {
                val x = response.optDouble("x", Double.NaN)
                val y = response.optDouble("y", Double.NaN)
                val devicePixelRatio = response.optDouble("devicePixelRatio", Double.NaN)
                if (!dispatchWebViewTap(session.webView, x, y, devicePixelRatio)) {
                    completeError(job, "unsupported")
                    return@evaluateJavascript
                }
                if (job.request.action == "native-input" &&
                    !commitNativeText(session.webView, job.request.text.orEmpty())
                ) {
                    completeError(job, "plugin_execution_failed")
                    return@evaluateJavascript
                }
            }
            response.put("version", 1)
            if (job.request.action != "coordinates") {
                response.remove("x")
                response.remove("y")
                response.remove("width")
                response.remove("height")
                response.remove("devicePixelRatio")
            }
            completed[job.id] = JSONObject().put("state", "done").put("response", response).toString()
            finish(job)
        }
    }

    private fun performWebViewFetch(job: Job, session: Session, verificationState: String) {
        Log.i(TAG, "browser_session_fetch_start plugin_id=${job.request.pluginId}")
        val script = webViewFetchScript(job)
        session.webView.evaluateJavascript(script) {
            mainHandler.postDelayed(
                { pollWebViewFetch(job, session, verificationState) },
                FETCH_POLL_MILLIS,
            )
        }
    }

    private fun performPageHtml(job: Job, session: Session, verificationState: String) {
        session.webView.evaluateJavascript(pageHtmlScript(job)) { raw ->
            if (!isCurrent(job, session)) return@evaluateJavascript
            val encoded = decodeEvaluation(raw)
            val result = encoded?.let { runCatching { JSONObject(it) }.getOrNull() }
            if (result?.optBoolean("ok", false) != true) {
                completeError(job, result?.optString("code") ?: "plugin_execution_failed")
                return@evaluateJavascript
            }
            val response = result.getJSONObject("response")
            if (isChallengeResponse(response)) {
                retryAfterChallenge(job, session)
            } else {
                completeSuccess(job, response, verificationState)
            }
        }
    }

    private fun pollWebViewFetch(job: Job, session: Session, verificationState: String) {
        if (!isCurrent(job, session)) return
        if (System.currentTimeMillis() >= job.deadlineUnixMs) {
            completeError(job, "timeout")
            return
        }
        val key = JSONObject.quote(job.id)
        val script = "(() => { const r=globalThis.__mgreadFetchResults?.[$key];" +
            "if(r===undefined)return null;delete globalThis.__mgreadFetchResults[$key];return r; })()"
        session.webView.evaluateJavascript(script) { raw ->
            val encoded = decodeEvaluation(raw)
            if (encoded == null) {
                mainHandler.postDelayed(
                    { pollWebViewFetch(job, session, verificationState) },
                    FETCH_POLL_MILLIS,
                )
                return@evaluateJavascript
            }
            val result = runCatching { JSONObject(encoded) }.getOrNull()
            if (result?.optBoolean("ok", false) != true) {
                completeError(job, result?.optString("code") ?: "plugin_execution_failed")
                return@evaluateJavascript
            }
            val response = result.getJSONObject("response")
            if (isChallengeResponse(response)) {
                retryAfterChallenge(job, session)
            } else {
                completeSuccess(job, response, verificationState)
            }
        }
    }

    private fun performHttp(job: Job, session: Session, verificationState: String) {
        val remaining = job.deadlineUnixMs - System.currentTimeMillis()
        if (remaining <= 0L) {
            completeError(job, "timeout")
            return
        }
        val request = job.request.copy(timeoutMs = remaining)
        val cookie = session.cookieManager.getCookie(request.url)
        val userAgent = session.webView.settings.userAgentString
        network.execute {
            try {
                val response = AndroidBrowserHttpTransport.execute(
                    request,
                    cookie,
                    userAgent,
                    job.cancelled,
                ) { job.connection = it }
                mainHandler.post {
                    response.setCookies.forEach { session.cookieManager.setCookie(response.finalUrl, it) }
                    session.cookieManager.flush()
                    if (response.status == 403 || looksLikeCloudflareChallenge(response.body)) {
                        retryAfterChallenge(job, session)
                    } else {
                        completeSuccess(job, responseObject(response), verificationState)
                    }
                }
            } catch (_: AndroidBrowserResponseTooLarge) {
                mainHandler.post { completeError(job, "overloaded") }
            } catch (_: InterruptedException) {
                mainHandler.post { completeError(job, "cancelled") }
            } catch (_: java.net.SocketTimeoutException) {
                mainHandler.post { completeError(job, "timeout") }
            } catch (_: Throwable) {
                mainHandler.post {
                    completeError(job, if (job.cancelled.get()) "cancelled" else "plugin_execution_failed")
                }
            }
        }
    }

    private fun completeSuccess(job: Job, response: JSONObject, verificationState: String) {
        if (!isCurrent(job)) return
        response.put("version", 1)
        response.put("verificationState", verificationState)
        Log.i(TAG, "browser_session_fetch_complete plugin_id=${job.request.pluginId}")
        completed[job.id] = JSONObject().put("state", "done").put("response", response).toString()
        finish(job)
    }

    private fun retryAfterChallenge(job: Job, session: Session) {
        if (!isCurrent(job, session)) return
        job.hadChallenge = true
        session.verifiedAt.remove(job.request.origin)
        Log.w(TAG, "browser_session_cf_detected phase=fetch plugin_id=${job.request.pluginId}")
        if (job.retries > 0 || job.request.interaction == "silent" || job.request.presentation == "hidden") {
            Log.i(TAG, "browser_session_interaction_required phase=fetch plugin_id=${job.request.pluginId}")
            completeError(job, "interaction_required")
            return
        }
        job.retries += 1
        Log.i(TAG, "browser_session_retry phase=fetch plugin_id=${job.request.pluginId}")
        loadForVerification(job, session)
    }

    private fun isChallengeResponse(response: JSONObject): Boolean {
        return response.optInt("status", 200) == 403 ||
            looksLikeCloudflareChallenge(response.optString("body"))
    }

    private fun completeError(job: Job, code: String) {
        if (jobs.remove(job.id) == null) return
        Log.i(TAG, "browser_session_complete_error code=$code")
        completed[job.id] = errorResult(code)
        sessions[job.request.pluginId]?.let { session ->
            expirePageAsyncResult(job, session)
            if (session.activeJobId == job.id) session.activeJobId = null
            if (!job.request.operation.startsWith("page.")) session.webView.stopLoading()
        }
        if (job.request.operation != "debug" && !job.request.operation.startsWith("page.") && foregroundPluginId == job.request.pluginId) hideForeground()
    }

    private fun expirePageAsyncResult(job: Job, session: Session) {
        if (job.request.operation !in PAGE_ASYNC_OPERATIONS) return
        runCatching {
            session.webView.evaluateJavascript(androidExpirePageAsyncScript(job.id), null)
        }
    }

    private fun finish(job: Job) {
        jobs.remove(job.id)
        sessions[job.request.pluginId]?.let { session ->
            if (session.activeJobId == job.id) session.activeJobId = null
            session.lastUsedAt = System.currentTimeMillis()
        }
        if (job.request.operation != "debug" && !job.request.operation.startsWith("page.") && foregroundPluginId == job.request.pluginId) hideForeground()
    }

    private fun isCurrent(job: Job, session: Session? = null): Boolean =
        !disposed.get() && !job.cancelled.get() && jobs[job.id] === job &&
            (session == null || session.activeJobId == job.id)

    private fun showForeground(session: Session, job: Job): Boolean {
        val currentActivity = activity ?: return false
        if (foregroundPluginId != null && foregroundPluginId != session.pluginId) hideForeground()
        if (foregroundDialog?.isShowing == true) return true
        session.contextWrapper.baseContext = currentActivity
        (session.webView.parent as? ViewGroup)?.removeView(session.webView)
        val root = LinearLayout(currentActivity).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.WHITE)
        }
        val bar = LinearLayout(currentActivity).apply {
            gravity = Gravity.CENTER_VERTICAL
            orientation = LinearLayout.HORIZONTAL
            setPadding(24, 16, 16, 16)
        }
        val status = TextView(currentActivity).apply {
            text = "${session.pluginName}正在进行探测 - ${androidPageActionLabel(job.request.operation)}"
            textSize = 18f
            setTextColor(Color.BLACK)
        }
        bar.addView(status, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        if (session.pluginId !in debugPinnedPlugins) {
            bar.addView(Button(currentActivity).apply { text = "隐藏"; setOnClickListener { hideForeground() } })
            bar.addView(Button(currentActivity).apply { text = "关闭"; setOnClickListener { closeForeground(session) } })
        }
        root.addView(bar, ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        val address = TextView(currentActivity).apply {
            text = session.webView.url.orEmpty()
            textSize = 13f
            setTextColor(Color.DKGRAY)
            setBackgroundColor(Color.rgb(245, 247, 250))
            setPadding(24, 12, 24, 12)
            setTextIsSelectable(true)
        }
        root.addView(address, ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        root.addView(session.webView, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            0,
            1f,
        ))
        val dialog = runCatching {
            Dialog(currentActivity, android.R.style.Theme_Material_Light_NoActionBar).apply {
                setContentView(root)
                setOnCancelListener { closeForeground(session) }
                setOnDismissListener {
                    (session.webView.parent as? ViewGroup)?.removeView(session.webView)
                    if (foregroundDialog === this) {
                        foregroundDialog = null
                        foregroundPluginId = null
                    }
                }
                show()
                window?.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
            }
        }.getOrElse {
            (session.webView.parent as? ViewGroup)?.removeView(session.webView)
            return false
        }
        foregroundDialog = dialog
        foregroundPluginId = job.request.pluginId
        session.statusView = status
        session.urlView = address
        Log.i(TAG, "browser_session_verification_window_shown plugin_id=${job.request.pluginId}")
        return true
    }

    private fun hideForeground() {
        val dialog = foregroundDialog
        foregroundDialog = null
        foregroundPluginId = null
        dialog?.dismiss()
    }

    private fun closeForeground(session: Session) {
        if (session.pluginId in debugPinnedPlugins) { hideForeground(); return }
        val activeJob = session.activeJobId?.let { jobs[it] }
        closePage(session)
        activeJob?.let { completeError(it, "interaction_required") }
    }

    private fun closePage(session: Session) {
        val dialog = if (foregroundPluginId == session.pluginId) foregroundDialog else null
        if (foregroundDialog === dialog) {
            foregroundDialog = null
            foregroundPluginId = null
        }
        dialog?.setOnCancelListener(null)
        dialog?.setOnDismissListener(null)
        dialog?.dismiss()
        (session.webView.parent as? ViewGroup)?.removeView(session.webView)
        session.webView.stopLoading()
        session.webView.destroy()
        if (sessions[session.pluginId] === session) sessions.remove(session.pluginId)
        session.activeJobId = null
        session.statusView = null
        session.urlView = null
        Log.i(
            TAG,
            "browser_session_manual_close plugin_id=${session.pluginId} " +
                "session_recreated_on_next_request=true",
        )
    }

    private fun webViewFetchScript(job: Job): String {
        val request = job.request
        val headersJson = JSONObject(request.headers).toString()
        val body = request.body?.let(JSONObject::quote) ?: "null"
        return """
            (() => {
              globalThis.__mgreadFetchResults ??= Object.create(null);
              const key = ${JSONObject.quote(job.id)};
              (async () => {
                try {
                  const response = await fetch(${JSONObject.quote(request.url)}, {
                    method: ${JSONObject.quote(request.method)},
                    headers: JSON.parse(${JSONObject.quote(headersJson)}),
                    body: $body,
                    credentials: 'include',
                    redirect: 'follow'
                  });
                  const body = await response.text();
                  if (new TextEncoder().encode(body).byteLength > ${request.maxResponseBytes}) {
                    globalThis.__mgreadFetchResults[key] = JSON.stringify({ok:false,code:'overloaded'});
                    return;
                  }
                  const finalUrl = new URL(response.url);
                  if (finalUrl.origin !== ${JSONObject.quote(request.origin)}) throw new Error('cross_origin');
                  const headers = {};
                  for (const name of ['cache-control','content-type','etag','expires','last-modified']) {
                    const value = response.headers.get(name); if (value !== null) headers[name] = value.slice(0,1024);
                  }
                  globalThis.__mgreadFetchResults[key] = JSON.stringify({ok:true,response:{
                    status:response.status,finalUrl:response.url,headers,body
                  }});
                } catch (_) {
                  globalThis.__mgreadFetchResults[key] = JSON.stringify({ok:false,code:'plugin_execution_failed'});
                }
              })();
              return 'started';
            })()
        """.trimIndent()
    }

    private fun pageHtmlScript(job: Job): String {
        val origin = JSONObject.quote(job.request.origin)
        return """
            (() => { try {
              const finalUrl = location.href;
              if (new URL(finalUrl).origin !== $origin) throw new Error('cross_origin');
              const body = document.documentElement?.outerHTML ?? '';
              if (new TextEncoder().encode(body).byteLength > ${job.request.maxResponseBytes}) {
                return JSON.stringify({ok:false,code:'overloaded'});
              }
              return JSON.stringify({ok:true,response:{status:200,finalUrl,
                headers:{'content-type':'text/html'},body}});
            } catch (_) {
              return JSON.stringify({ok:false,code:'plugin_execution_failed'});
            } })()
        """.trimIndent()
    }

    private fun interactionTargetScript(request: AndroidBrowserSessionRequest): String {
        val selector = JSONObject.quote(request.selector)
        return """
            (() => { try { const e=document.querySelector($selector); if(!e) return JSON.stringify({accepted:false,action:'${request.action}'}); const r=e.getBoundingClientRect(); if(!Number.isFinite(r.x)||!Number.isFinite(r.y)||r.width<=0||r.height<=0) return JSON.stringify({accepted:false,action:'${request.action}'}); return JSON.stringify({accepted:true,action:'${request.action}',x:r.x+r.width/2,y:r.y+r.height/2,width:r.width,height:r.height,devicePixelRatio:window.devicePixelRatio||1}); } catch (_) { return JSON.stringify({accepted:false,action:'${request.action}'}); } })()
        """.trimIndent()
    }

    private fun dispatchWebViewTap(
        webView: WebView,
        cssX: Double,
        cssY: Double,
        devicePixelRatio: Double,
    ): Boolean {
        if (!cssX.isFinite() || !cssY.isFinite() || !devicePixelRatio.isFinite() ||
            devicePixelRatio <= 0.0 || devicePixelRatio > 8.0 ||
            !webView.isAttachedToWindow
        ) return false
        val x = (cssX * devicePixelRatio).toFloat()
        val y = (cssY * devicePixelRatio).toFloat()
        if (!x.isFinite() || !y.isFinite() || x < 0f || y < 0f ||
            x >= webView.width || y >= webView.height
        ) return false
        val now = android.os.SystemClock.uptimeMillis()
        val down = MotionEvent.obtain(now, now, MotionEvent.ACTION_DOWN, x, y, 0)
        val up = MotionEvent.obtain(now, now + 16L, MotionEvent.ACTION_UP, x, y, 0)
        down.source = InputDevice.SOURCE_TOUCHSCREEN
        up.source = InputDevice.SOURCE_TOUCHSCREEN
        return try {
            val downAccepted = webView.dispatchTouchEvent(down)
            val upAccepted = webView.dispatchTouchEvent(up)
            downAccepted && upAccepted
        } finally {
            down.recycle()
            up.recycle()
        }
    }

    private fun commitNativeText(webView: WebView, text: String): Boolean {
        if (!webView.isAttachedToWindow || !webView.requestFocus(View.FOCUS_DOWN)) return false
        val editorInfo = EditorInfo()
        val inputConnection = webView.onCreateInputConnection(editorInfo) ?: return false
        return try {
            inputConnection.commitText(text, 1)
        } finally {
            inputConnection.closeConnection()
        }
    }

    private fun responseObject(value: AndroidBrowserHttpResponse): JSONObject = JSONObject()
        .put("status", value.status)
        .put("finalUrl", value.finalUrl)
        .put("headers", JSONObject(value.headers))
        .put("body", value.body)

    private fun decodeEvaluation(raw: String?): String? =
        runCatching { JSONTokener(raw ?: return null).nextValue() as? String }.getOrNull()

    private fun profileName(pluginId: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(pluginId.toByteArray(Charsets.UTF_8))
            .take(12)
            .joinToString("") { "%02x".format(it) }
        return "mgread-$digest"
    }

    private fun errorResult(code: String): String = JSONObject()
        .put("state", "error")
        .put("code", code)
        .toString()

    private companion object {
        const val FETCH_POLL_MILLIS = 50L
        const val INTERACTION_GRACE_MILLIS = 1_500L
        const val MAX_PENDING_REQUESTS = 16
        const val MAX_RESIDENT_WEBVIEWS = 8
        const val PAGE_POLL_MILLIS = 400L
        const val PAGE_OPERATION_POLL_MILLIS = 50L
        const val POLL_SLEEP_MILLIS = 10L
        const val MAX_POLL_WAIT_MILLIS = 120_000L
        const val VERIFICATION_CACHE_MILLIS = 10 * 60 * 1000L
        const val TAG = "MgReadAndroidBrowser"
        const val PENDING_RESULT = "{\"state\":\"pending\"}"
        val PAGE_ASYNC_OPERATIONS = setOf("page.evaluate", "page.html", "page.fetch")
        val PAGE_PROBE_SCRIPT = """
            (() => { try { const text=(document.title+' '+(document.documentElement?.innerText||'')).slice(0,200000);
            return JSON.stringify({href:location.href,ready:document.readyState!=='loading',
            challenge:/(cf-challenge|cf-turnstile|just a moment|checking your browser|challenge-platform)/i.test(text)});
            } catch (_) { return null; } })()
        """.trimIndent()
    }
}
