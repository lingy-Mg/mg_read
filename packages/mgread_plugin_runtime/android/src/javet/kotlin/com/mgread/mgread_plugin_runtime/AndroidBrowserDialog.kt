/**
 * Host-owned browser presentation shared by both Android Node backends.
 * The resident WebView remains owned by AndroidBrowserSessionHost; this dialog
 * only arranges it above a bottom toolbar. System bars, cutouts and IME insets
 * are applied once to the content root, including Android 15+ edge-to-edge.
 * All dimensions are dp; hiding must preserve the page and its login state.
 */
package com.mgread.mgread_plugin_runtime

import android.app.Activity
import android.app.Dialog
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.os.Build
import android.os.Bundle
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.webkit.WebView
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.max
import kotlin.math.roundToInt

internal class AndroidBrowserDialog(
    activity: Activity,
    pluginName: String,
    webView: WebView,
    pinned: Boolean,
    onHide: () -> Unit,
    onClose: () -> Unit,
) : Dialog(activity, android.R.style.Theme_Material_Light_NoActionBar) {
    private val ink = Color.rgb(30, 41, 59)
    private val muted = Color.rgb(100, 116, 139)
    private val surface = Color.rgb(245, 247, 250)
    private fun dp(value: Int) = (value * context.resources.displayMetrics.density).roundToInt()

    val titleView = TextView(context).apply {
        text = pluginName
        textSize = 14f
        setTextColor(ink)
        setTypeface(typeface, Typeface.BOLD)
        setSingleLine()
        ellipsize = TextUtils.TruncateAt.END
    }
    val addressView = TextView(context).apply {
        text = webView.url.orEmpty()
        textSize = 12f
        setTextColor(muted)
        setSingleLine()
        ellipsize = TextUtils.TruncateAt.MIDDLE
        setTextIsSelectable(true)
        contentDescription = "当前网页地址"
    }
    private val root = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        setBackgroundColor(surface)
    }

    init {
        root.addView(webView, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        val toolbar = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(16), dp(10), dp(10), dp(10))
            background = rounded(Color.WHITE, 24)
            elevation = dp(2).toFloat()
        }
        val identity = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, 0, dp(12), 0)
            addView(titleView)
            addView(addressView, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { topMargin = dp(4) })
        }
        toolbar.addView(identity, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        toolbar.addView(action("收起", "收起网页，保留当前页面", false, onHide))
        if (!pinned) {
            toolbar.addView(action("×", "关闭网页", true, onClose), LinearLayout.LayoutParams(
                dp(48), dp(48),
            ).apply { marginStart = dp(6) })
        }
        root.addView(toolbar, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
        ).apply { setMargins(dp(12), dp(10), dp(12), dp(10)) })
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(root)
        window?.apply {
            setBackgroundDrawableResource(android.R.color.transparent)
            setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                setDecorFitsSystemWindows(false)
                insetsController?.setSystemBarsAppearance(
                    WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or
                        WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS,
                    WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or
                        WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS,
                )
                root.setOnApplyWindowInsetsListener { view, insets ->
                    val bars = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
                    val keyboard = insets.getInsets(WindowInsets.Type.ime())
                    view.setPadding(bars.left, bars.top, bars.right, max(bars.bottom, keyboard.bottom))
                    // Descendants must not apply these insets to the WebView again.
                    WindowInsets.CONSUMED
                }
                root.requestApplyInsets()
            } else {
                root.fitsSystemWindows = true
                @Suppress("DEPRECATION")
                decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR or
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR else 0
            }
            @Suppress("DEPRECATION")
            statusBarColor = surface
            @Suppress("DEPRECATION")
            navigationBarColor = surface
        }
    }

    private fun rounded(color: Int, radius: Int) = GradientDrawable().apply {
        setColor(color)
        cornerRadius = dp(radius).toFloat()
    }

    private fun action(label: String, description: String, icon: Boolean, callback: () -> Unit) =
        TextView(context).apply {
            text = label
            contentDescription = description
            textSize = if (icon) 26f else 13f
            setTextColor(if (icon) muted else ink)
            gravity = Gravity.CENTER
            minWidth = dp(48)
            minHeight = dp(48)
            setPadding(dp(12), 0, dp(12), 0)
            background = RippleDrawable(
                ColorStateList.valueOf(Color.rgb(222, 228, 237)),
                rounded(surface, 24), null,
            )
            isFocusable = true
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
            accessibilityDelegate = object : View.AccessibilityDelegate() {
                override fun onInitializeAccessibilityNodeInfo(host: View, info: android.view.accessibility.AccessibilityNodeInfo) {
                    super.onInitializeAccessibilityNodeInfo(host, info)
                    info.className = android.widget.Button::class.java.name
                }
            }
            setOnClickListener { callback() }
        }
}
