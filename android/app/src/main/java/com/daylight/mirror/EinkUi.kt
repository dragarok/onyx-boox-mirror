// EinkUi.kt — shared look for the companion's own screens (chooser, settings).
//
// E-ink rules: black on white with one dark grey for secondary text; no animation,
// ripples or shadows (each animation frame is a panel refresh); pressed = instant
// inversion; big targets.

package com.daylight.mirror

import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.StateListDrawable
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import android.widget.TextView

object EinkUi {
    const val INK = Color.BLACK
    const val PAPER = Color.WHITE
    val SECONDARY = Color.rgb(0x4A, 0x4A, 0x4A)
    val PRESSED = intArrayOf(android.R.attr.state_pressed)
    val SELECTED = intArrayOf(android.R.attr.state_selected)

    fun dp(ctx: Context, v: Float) = (v * ctx.resources.displayMetrics.density).toInt()

    /// Black normally, white while pressed or selected (for text on an inverting surface).
    val inverting = ColorStateList(arrayOf(PRESSED, SELECTED, intArrayOf()), intArrayOf(PAPER, PAPER, INK))
    val invertingSecondary = ColorStateList(arrayOf(PRESSED, SELECTED, intArrayOf()), intArrayOf(PAPER, PAPER, SECONDARY))

    fun text(ctx: Context, sizeSp: Float, color: Int, bold: Boolean = false) = TextView(ctx).apply {
        textSize = sizeSp
        setTextColor(color)
        gravity = Gravity.CENTER_HORIZONTAL
        typeface = Typeface.create("sans-serif", if (bold) Typeface.BOLD else Typeface.NORMAL)
        includeFontPadding = false
        setLineSpacing(dp(ctx, 4f).toFloat(), 1f)
    }

    /// White with a black outline; solid black while pressed or selected. No ripple.
    fun pressable(ctx: Context, radius: Float, stroke: Float): StateListDrawable {
        fun shape(fill: Int) = GradientDrawable().apply {
            cornerRadius = dp(ctx, radius).toFloat()
            setColor(fill)
            setStroke(dp(ctx, stroke), INK)
        }
        return StateListDrawable().apply {
            addState(PRESSED, shape(INK))
            addState(SELECTED, shape(INK))
            addState(intArrayOf(), shape(PAPER))
        }
    }

    /// Outlined pill button.
    fun button(ctx: Context, label: String, onClick: () -> Unit) = text(ctx, 18f, INK, bold = true).apply {
        text = label
        setTextColor(inverting)
        background = pressable(ctx, radius = 999f, stroke = 2.5f)
        setPadding(dp(ctx, 28f), dp(ctx, 14f), dp(ctx, 28f), dp(ctx, 14f))
        isClickable = true
        setOnClickListener { onClick() }
    }

    /// Checkbox + label row with a generous hit area.
    class CheckRow(ctx: Context, label: String, onToggle: (Boolean) -> Unit) : LinearLayout(ctx) {
        private val box = CheckBoxMark(ctx)
        var checked: Boolean
            get() = box.checked
            set(v) { box.checked = v }

        init {
            orientation = HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(ctx, 12f), dp(ctx, 12f), dp(ctx, 12f), dp(ctx, 12f))
            addView(box, LayoutParams(dp(ctx, 30f), dp(ctx, 30f)))
            addView(text(ctx, 18f, INK).apply {
                text = label
                gravity = Gravity.START
                setPadding(dp(ctx, 16f), 0, 0, 0)
            })
            isClickable = true
            setOnClickListener { checked = !checked; onToggle(checked) }
        }
    }

    /// Square checkbox: outlined when off, solid black with a white tick when on.
    class CheckBoxMark(ctx: Context) : View(ctx) {
        var checked = false
            set(v) { field = v; invalidate() }
        private val p = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            strokeWidth = dp(ctx, 2.5f).toFloat()
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
        }

        override fun onDraw(canvas: Canvas) {
            val inset = dp(context, 1.5f).toFloat()
            val r = RectF(inset, inset, width - inset, height - inset)
            val corner = dp(context, 6f).toFloat()
            p.color = INK
            p.style = if (checked) Paint.Style.FILL else Paint.Style.STROKE
            canvas.drawRoundRect(r, corner, corner, p)
            if (checked) {
                p.color = PAPER
                p.style = Paint.Style.STROKE
                canvas.drawPath(Path().apply {
                    moveTo(r.left + r.width() * 0.24f, r.top + r.height() * 0.52f)
                    lineTo(r.left + r.width() * 0.43f, r.top + r.height() * 0.70f)
                    lineTo(r.left + r.width() * 0.77f, r.top + r.height() * 0.32f)
                }, p)
            }
        }
    }

    /// Segmented control: equal segments in one outlined row; the selected one is solid.
    class Segmented(ctx: Context, private val onSelect: (String) -> Unit) : LinearLayout(ctx) {
        private val segments = mutableListOf<Pair<String, TextView>>()

        init { orientation = HORIZONTAL }

        fun setOptions(options: List<Pair<String, String>>) {
            removeAllViews()
            segments.clear()
            options.forEachIndexed { i, (value, label) ->
                val first = i == 0
                val last = i == options.size - 1
                val seg = text(context, 17f, INK, bold = true).apply {
                    text = label
                    setTextColor(inverting)
                    gravity = Gravity.CENTER
                    maxLines = 2
                    setPadding(dp(context, 14f), dp(context, 16f), dp(context, 14f), dp(context, 16f))
                    background = segmentBackground(first, last)
                    isClickable = true
                    setOnClickListener {
                        if (!isSelected) { select(value); onSelect(value) }
                    }
                }
                addView(seg, LayoutParams(0, LayoutParams.MATCH_PARENT, 1f).apply {
                    if (!first) marginStart = -dp(context, 2.5f)  // share borders
                })
                segments += value to seg
            }
        }

        fun select(value: String?) {
            segments.forEach { (v, view) -> view.isSelected = v == value }
        }

        private fun segmentBackground(first: Boolean, last: Boolean): StateListDrawable {
            val r = dp(context, 16f).toFloat()
            val radii = floatArrayOf(
                if (first) r else 0f, if (first) r else 0f,   // top-left
                if (last) r else 0f, if (last) r else 0f,     // top-right
                if (last) r else 0f, if (last) r else 0f,     // bottom-right
                if (first) r else 0f, if (first) r else 0f,   // bottom-left
            )
            fun shape(fill: Int) = GradientDrawable().apply {
                cornerRadii = radii
                setColor(fill)
                setStroke(dp(context, 2.5f), INK)
            }
            return StateListDrawable().apply {
                addState(PRESSED, shape(INK))
                addState(SELECTED, shape(INK))
                addState(intArrayOf(), shape(PAPER))
            }
        }
    }
}
