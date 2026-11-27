// ChooserView.kt — full-screen status and mode chooser, shown while no stream is connected.
//
// E-ink look from EinkUi; whole cards are the targets, and line drawings explain the
// two modes at a glance.
//
// States: message (looking for the Mac, connecting, errors) · chooser · starting.

package com.daylight.mirror

import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.StateListDrawable
import android.text.TextUtils
import com.daylight.mirror.EinkUi.INK as ink
import com.daylight.mirror.EinkUi.PAPER as paper
import com.daylight.mirror.EinkUi.PRESSED as pressedState
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView

class ChooserView(context: Context) : FrameLayout(context) {

    /// Card tapped: mode is "mirror" or "extend".
    var onPick: ((mode: String, remember: Boolean) -> Unit)? = null
    /// "Choose another mode" tapped on the starting screen.
    var onChange: (() -> Unit)? = null
    /// "Settings" tapped on the chooser.
    var onSettings: (() -> Unit)? = null

    private fun dp(v: Float) = EinkUi.dp(context, v)
    private val secondary = EinkUi.SECONDARY
    private val inverting = EinkUi.inverting
    private val invertingSecondary = EinkUi.invertingSecondary

    private val column: LinearLayout
    private val eyebrow: TextView
    /// Exposed for the non-e-ink "waiting" pulse.
    val title: TextView
    private val subtitle: TextView
    private val cards: LinearLayout
    private val mirrorCard: OptionCard
    private val extendCard: OptionCard
    private val rememberRow: EinkUi.CheckRow
    private val changeButton: TextView
    private val settingsButton: TextView
    private val footer: TextView

    val remember: Boolean get() = rememberRow.checked

    init {
        setBackgroundColor(paper)
        isClickable = true  // swallow touches meant for the surface underneath

        eyebrow = text(15f, secondary, bold = true).apply {
            text = "DAYLIGHT MIRROR"
            letterSpacing = 0.18f
        }
        title = text(34f, ink, bold = true).apply { setPadding(0, dp(14f), 0, 0) }
        subtitle = text(19f, secondary).apply { setPadding(0, dp(10f), 0, 0) }

        mirrorCard = OptionCard("mirror", "Mirror Mac", "Show your Mac's screen on the BOOX")
        extendCard = OptionCard("extend", "Second monitor", "Use the BOOX as an extra display")
        cards = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(0, dp(32f), 0, 0)
            addView(mirrorCard, cardParams(horizontal = true))
            addView(extendCard, cardParams(horizontal = true))
        }

        rememberRow = EinkUi.CheckRow(context, "Remember my choice and start it automatically") {}

        changeButton = EinkUi.button(context, "Choose another mode") { onChange?.invoke() }
        settingsButton = EinkUi.button(context, "Settings") { onSettings?.invoke() }

        footer = text(15f, secondary).apply {
            text = "Tap with four fingers for settings while mirroring  ·  Back stops mirroring"
        }

        column = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(32f), dp(32f), dp(32f), dp(32f))
            val wrap = { LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT) }
            addView(eyebrow, wrap())
            addView(title, wrap())
            addView(subtitle, wrap())
            addView(cards, wrap())  // natural width — never squeezed to the widest text line
            addView(rememberRow, wrap().apply { topMargin = dp(20f) })
            addView(changeButton, wrap().apply { topMargin = dp(40f) })
        }
        addView(column, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT, Gravity.CENTER))
        // Secondary actions sit at the edges, out of the main flow
        addView(settingsButton, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT,
            Gravity.TOP or Gravity.END).apply { setMargins(0, dp(24f), dp(28f), 0) })
        addView(footer, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT,
            Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL).apply { bottomMargin = dp(24f) })
        showMessage("Looking for your Mac…", null)
    }

    // MARK: - States
    //
    // The activity re-reports state every couple of seconds; only touch the views when
    // something changed — each redraw is an e-ink refresh, and re-showing the chooser
    // must not reset a checkbox the user just ticked.

    private var shown: String? = null

    fun showMessage(titleText: String, hint: String?) {
        val key = "message|$titleText|$hint"
        if (shown == key) return
        shown = key
        title.text = titleText
        subtitle.text = hint ?: ""
        subtitle.visibility = if (hint.isNullOrEmpty()) View.GONE else View.VISIBLE
        cards.visibility = View.GONE
        rememberRow.visibility = View.GONE
        changeButton.visibility = View.GONE
        settingsButton.visibility = View.GONE
        footer.visibility = View.GONE
    }

    /// lastMode: the Mac's current setting ("mirror" / "extended"), marked "Last used".
    fun showChooser(macName: String, lastMode: String, remembered: Boolean) {
        val key = "chooser|$macName|$lastMode"
        if (shown == key) return
        val entering = shown?.startsWith("chooser|") != true
        shown = key
        title.text = "$macName is ready"
        subtitle.text = "How do you want to use the BOOX?"
        subtitle.visibility = View.VISIBLE
        mirrorCard.setLastUsed(lastMode == "mirror")
        extendCard.setLastUsed(lastMode == "extended" || lastMode == "extend")
        if (entering) rememberRow.checked = remembered
        cards.visibility = View.VISIBLE
        rememberRow.visibility = View.VISIBLE
        changeButton.visibility = View.GONE
        settingsButton.visibility = View.VISIBLE
        footer.visibility = View.VISIBLE
    }

    fun showStarting(modeLabel: String, macName: String) {
        val key = "starting|$modeLabel|$macName"
        if (shown == key) return
        shown = key
        title.text = "Starting $modeLabel"
        subtitle.text = "on $macName"
        subtitle.visibility = View.VISIBLE
        cards.visibility = View.GONE
        rememberRow.visibility = View.GONE
        changeButton.visibility = View.VISIBLE
        settingsButton.visibility = View.GONE
        footer.visibility = View.GONE
    }

    // Side by side in landscape, stacked in portrait.
    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        val horizontal = w >= h
        if ((cards.orientation == LinearLayout.HORIZONTAL) != horizontal) {
            post {
                cards.orientation = if (horizontal) LinearLayout.HORIZONTAL else LinearLayout.VERTICAL
                for (i in 0 until cards.childCount) cards.getChildAt(i).layoutParams = cardParams(horizontal)
                cards.requestLayout()
            }
        }
    }

    // MARK: - Building blocks

    private fun cardParams(horizontal: Boolean): LinearLayout.LayoutParams {
        return LinearLayout.LayoutParams(dp(360f), LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            if (horizontal) setMargins(dp(14f), 0, dp(14f), 0) else setMargins(0, dp(10f), 0, dp(10f))
        }
    }

    private fun text(sizeSp: Float, color: Int, bold: Boolean = false) = EinkUi.text(context, sizeSp, color, bold)
    private fun pressable(radius: Float, stroke: Float) = EinkUi.pressable(context, radius, stroke)

    /// One mode: drawing, name, one-line description, optional "Last used" tag.
    private inner class OptionCard(val mode: String, name: String, description: String) : LinearLayout(context) {
        private val badge: TextView
        private val normalBg = pressable(radius = 22f, stroke = 2.5f)
        private val lastUsedBg = pressable(radius = 22f, stroke = 5f)

        init {
            orientation = VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            background = normalBg
            setPadding(dp(24f), dp(18f), dp(24f), dp(24f))
            isClickable = true
            setOnClickListener { onPick?.invoke(mode, remember) }

            badge = text(12f, paper, bold = true).apply {
                text = "LAST USED"
                letterSpacing = 0.14f
                setTextColor(ColorStateList(arrayOf(pressedState, intArrayOf()), intArrayOf(ink, paper)))
                background = StateListDrawable().apply {
                    addState(pressedState, GradientDrawable().apply { cornerRadius = dp(999f).toFloat(); setColor(paper) })
                    addState(intArrayOf(), GradientDrawable().apply { cornerRadius = dp(999f).toFloat(); setColor(ink) })
                }
                setPadding(dp(12f), dp(6f), dp(12f), dp(6f))
                isDuplicateParentStateEnabled = true
            }
            // Keeps both cards the same height whether or not the tag is shown
            val badgeSlot = FrameLayout(context).apply {
                addView(badge, FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER))
                isDuplicateParentStateEnabled = true
            }
            addView(badgeSlot, LayoutParams(LayoutParams.MATCH_PARENT, dp(28f)))
            addView(ModeDrawing(mode).apply { isDuplicateParentStateEnabled = true },
                LayoutParams(dp(280f), dp(130f)).apply { topMargin = dp(6f) })
            addView(text(24f, ink, bold = true).apply {
                text = name
                setTextColor(inverting)
                isDuplicateParentStateEnabled = true
                setPadding(0, dp(16f), 0, 0)
            })
            addView(text(16f, secondary).apply {
                text = description
                setTextColor(invertingSecondary)
                isDuplicateParentStateEnabled = true
                maxLines = 1
                ellipsize = TextUtils.TruncateAt.END
                setPadding(0, dp(8f), 0, 0)
            })
        }

        fun setLastUsed(on: Boolean) {
            badge.visibility = if (on) View.VISIBLE else View.INVISIBLE
            background = if (on) lastUsedBg else normalBg
        }
    }

    /// Line drawing of a laptop and a tablet: same picture on both (mirror), or one
    /// desktop spanning both with a window crossing the gap (second monitor).
    private inner class ModeDrawing(private val mode: String) : View(context) {
        private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = dp(3f).toFloat()
            strokeJoin = Paint.Join.ROUND
            strokeCap = Paint.Cap.ROUND
        }
        private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }

        override fun onDraw(canvas: Canvas) {
            val c = if (isPressed) paper else ink
            stroke.color = c
            fill.color = c
            val w = width.toFloat()
            val h = height.toFloat()
            val u = h / 10f  // drawing unit

            // Laptop: screen + base
            val lap = RectF(w * 0.02f, u * 1.2f, w * 0.48f, u * 7.6f)
            canvas.drawRoundRect(lap, u * 0.5f, u * 0.5f, stroke)
            val base = Path().apply {
                moveTo(lap.left - u * 0.6f, u * 8.8f)
                lineTo(lap.right + u * 0.6f, u * 8.8f)
                lineTo(lap.right, lap.bottom)
                lineTo(lap.left, lap.bottom)
                close()
            }
            canvas.drawPath(base, stroke)

            // Tablet
            val tab = RectF(w * 0.58f, u * 1.6f, w * 0.98f, u * 8.6f)
            canvas.drawRoundRect(tab, u * 0.7f, u * 0.7f, stroke)

            val lapIn = RectF(lap.left + u * 0.7f, lap.top + u * 0.7f, lap.right - u * 0.7f, lap.bottom - u * 0.7f)
            val tabIn = RectF(tab.left + u * 0.7f, tab.top + u * 0.7f, tab.right - u * 0.7f, tab.bottom - u * 0.7f)

            if (mode == "mirror") {
                content(canvas, lapIn, u)
                content(canvas, tabIn, u)
                // "same as" mark between the two
                val cx = (lap.right + tab.left) / 2f
                canvas.drawLine(cx - u * 0.6f, u * 4.3f, cx + u * 0.6f, u * 4.3f, stroke)
                canvas.drawLine(cx - u * 0.6f, u * 5.3f, cx + u * 0.6f, u * 5.3f, stroke)
            } else {
                // Laptop keeps its own content
                content(canvas, lapIn, u)
                // A window that continues from the laptop onto the tablet
                val win = RectF(tabIn.left, tabIn.top + u * 0.6f, tabIn.right - u * 0.4f, tabIn.top + u * 4.2f)
                canvas.drawRoundRect(win, u * 0.3f, u * 0.3f, stroke)
                canvas.drawLine(win.left, win.top + u * 1.1f, win.right, win.top + u * 1.1f, stroke)
                for (i in 0..1) {
                    val y = win.top + u * (2.0f + i * 0.9f)
                    canvas.drawLine(win.left + u * 0.6f, y, win.right - u * (1.5f + i), y, stroke)
                }
                // Arrow: the desktop extends to the right
                val ay = u * 9.6f
                val ax0 = lap.right - u * 1.5f
                val ax1 = tab.left + u * 2.5f
                canvas.drawLine(ax0, ay, ax1, ay, stroke)
                canvas.drawLine(ax1, ay, ax1 - u * 0.6f, ay - u * 0.5f, stroke)
                canvas.drawLine(ax1, ay, ax1 - u * 0.6f, ay + u * 0.5f, stroke)
            }
        }

        /// A tiny "screen": a title bar block and three lines of text.
        private fun content(canvas: Canvas, r: RectF, u: Float) {
            canvas.drawRoundRect(RectF(r.left, r.top, r.left + r.width() * 0.45f, r.top + u * 0.9f), u * 0.2f, u * 0.2f, fill)
            for (i in 0..2) {
                val y = r.top + u * (2.2f + i * 1.1f)
                val end = r.right - r.width() * (0.1f + i * 0.18f)
                canvas.drawLine(r.left, y, end, y, stroke)
            }
        }
    }
}
