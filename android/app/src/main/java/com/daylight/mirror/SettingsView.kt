// SettingsView.kt — the Mac's BOOX settings, changed from the tablet.
//
// Opens with a four-finger tap while mirroring, or from the chooser. Reads the Mac's
// settings over the remote-control port (SETTINGS) and applies changes with SET, so the
// Mac menu and the tablet always agree. Changes that rebuild the display (mode,
// resolution, colour) close the panel so you see the result as it reconnects.

package com.daylight.mirror

import android.content.Context
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

class SettingsView(context: Context) : FrameLayout(context) {

    /// Send one SET; the activity runs it on its network thread.
    var onSet: ((key: String, value: String) -> Unit)? = null
    var onRefresh: (() -> Unit)? = null
    var onStop: (() -> Unit)? = null
    var onRememberChanged: ((Boolean) -> Unit)? = null
    var onClose: (() -> Unit)? = null

    private fun dp(v: Float) = EinkUi.dp(context, v)
    private fun text(size: Float, color: Int, bold: Boolean = false) = EinkUi.text(context, size, color, bold)

    private val status: TextView
    private val modeControl = EinkUi.Segmented(context) { v -> changeAndClose("mode", v) }
    private val modeNote: TextView
    private val resolutionControls = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
    private val colorControl = EinkUi.Segmented(context) { v -> changeAndClose("color", v) }
    private val einkControl = EinkUi.Segmented(context) { v -> onSet?.invoke("eink", v); describeEink(v) }
    private val einkHint: TextView
    private val rememberRow: EinkUi.CheckRow
    private val stopButton: TextView
    private val content: LinearLayout
    /// Two columns in landscape (everything on one screen — no scrolling on e-ink),
    /// one column in portrait.
    private val body: LinearLayout

    init {
        setBackgroundColor(EinkUi.PAPER)
        isClickable = true  // keep touches off the mirrored screen underneath

        val header = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(text(32f, EinkUi.INK, bold = true).apply {
                text = "Settings"
                gravity = Gravity.START
            }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            addView(EinkUi.button(context, "Done") { onClose?.invoke() })
        }
        status = text(16f, EinkUi.SECONDARY).apply {
            gravity = Gravity.START
            setPadding(0, dp(8f), 0, 0)
        }

        modeControl.setOptions(listOf("mirror" to "Mirror Mac", "extend" to "Second monitor"))
        modeNote = text(16f, EinkUi.SECONDARY).apply {
            gravity = Gravity.START
            text = "Mirroring only over Tailscale. Second monitor works on USB or the same Wi-Fi as the Mac."
            visibility = View.GONE
        }
        colorControl.setOptions(listOf("on" to "Colour", "off" to "Greyscale"))
        einkControl.setOptions(listOf("auto" to "Auto", "quality" to "Quality", "balanced" to "Balanced", "fast" to "Fast"))
        einkHint = text(15f, EinkUi.SECONDARY).apply {
            gravity = Gravity.START
            setPadding(dp(4f), dp(10f), 0, 0)
        }
        rememberRow = EinkUi.CheckRow(context, "Start my last choice automatically when the app opens") {
            onRememberChanged?.invoke(it)
        }
        val refreshButton = EinkUi.button(context, "Full refresh") { onRefresh?.invoke() }
        stopButton = EinkUi.button(context, "Stop mirroring") { onStop?.invoke() }

        val left = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            addView(section("Use the BOOX as"))
            addView(modeControl, fill())
            addView(modeNote, fill())
            addView(section("Resolution"))
            addView(resolutionControls, fill())
        }
        val right = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            addView(section("Colour"))
            addView(colorControl, fill())
            addView(section("E-ink refresh"))
            addView(einkControl, fill())
            addView(einkHint)
            addView(rememberRow, LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { topMargin = dp(18f); marginStart = -dp(12f) })
            addView(LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                addView(refreshButton)
                addView(stopButton, LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply { marginStart = dp(16f) })
            }, LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { topMargin = dp(18f) })
        }
        body = LinearLayout(context).apply {
            addView(left)
            addView(right)
        }
        layoutBody(horizontal = resources.displayMetrics.widthPixels >= resources.displayMetrics.heightPixels)

        content = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(48f), dp(32f), dp(48f), dp(40f))
            addView(header)
            addView(status)
            addView(body, fill())
        }
        val scroll = ScrollView(context).apply {
            isVerticalScrollBarEnabled = false
            overScrollMode = View.OVER_SCROLL_NEVER  // no glow animation on e-ink
            addView(content)
        }
        addView(scroll, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        showLoading()
    }

    private fun layoutBody(horizontal: Boolean) {
        body.orientation = if (horizontal) LinearLayout.HORIZONTAL else LinearLayout.VERTICAL
        val gap = dp(56f)
        for (i in 0 until body.childCount) {
            body.getChildAt(i).layoutParams = if (horizontal) {
                LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
                    if (i > 0) marginStart = gap
                }
            } else fill()
        }
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        val horizontal = w >= h
        if ((body.orientation == LinearLayout.HORIZONTAL) != horizontal) post { layoutBody(horizontal) }
    }

    fun showLoading() {
        status.text = "Reading settings from your Mac…"
        content.alpha = 1f
    }

    fun showUnavailable() {
        status.text = "Your Mac didn't answer. Check that it's awake and Daylight Mirror is open."
    }

    /// SETTINGS reply body: key=value pairs joined by ";" (see MirrorEngine.remoteSettings).
    fun update(settings: Map<String, String>, macName: String, via: String, remembered: Boolean) {
        val running = settings["state"] == "running" || settings["state"] == "starting"
        status.text = if (running) "$macName · connected over $via" else "$macName · not mirroring"
        modeControl.select(if (settings["mode"] == "extended") "extend" else "mirror")
        val away = settings["remote"] == "1"
        modeControl.visibility = if (away) View.GONE else View.VISIBLE
        modeNote.visibility = if (away) View.VISIBLE else View.GONE
        colorControl.select(if (settings["color"] == "1") "on" else "off")
        val eink = settings["eink"] ?: "auto"
        einkControl.select(eink)
        describeEink(eink)
        rememberRow.checked = remembered
        stopButton.visibility = if (running) View.VISIBLE else View.GONE
        buildResolutions(settings["presets"].orEmpty(), settings["resolution"])
    }

    /// Presets as rows of two: "boox-retina:Retina (1240×840)" → value, label.
    private fun buildResolutions(spec: String, current: String?) {
        resolutionControls.removeAllViews()
        val options = spec.split("|").mapNotNull { item ->
            val i = item.indexOf(':')
            if (i <= 0) null else item.substring(0, i) to item.substring(i + 1).replace(" (", "\n(")
        }
        options.chunked(2).forEachIndexed { row, chunk ->
            val seg = EinkUi.Segmented(context) { v ->
                changeAndClose("resolution", v)
            }
            seg.setOptions(chunk)
            seg.select(current)
            resolutionControls.addView(seg, LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { if (row > 0) topMargin = dp(12f) })
        }
    }

    private fun describeEink(mode: String) {
        einkHint.text = when (mode) {
            "auto" -> "Fast while things move, a clean redraw once they settle."
            "quality" -> "Best greys and least ghosting; slowest to update."
            "balanced" -> "Quicker updates with light ghosting."
            "fast" -> "Lowest latency for scrolling and video; some ghosting."
            else -> ""
        }
    }

    /// Mode, resolution and colour rebuild the Mac's display: apply, then get out of the way.
    private fun changeAndClose(key: String, value: String) {
        onSet?.invoke(key, value)
        onClose?.invoke()
    }

    private fun section(title: String) = text(15f, EinkUi.SECONDARY, bold = true).apply {
        text = title.uppercase()
        letterSpacing = 0.14f
        gravity = Gravity.START
        setPadding(0, dp(26f), 0, dp(12f))
    }

    private fun fill() = LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
}
