// EinkController — drives the BOOX (Onyx) e-ink panel from the mirror app.
//
// Onyx firmware adds hidden methods to android.view.View that forward to
// android.onyx.ViewUpdateHelper, which sends custom transactions to SurfaceFlinger's
// EPD backend. We call them by reflection (they are not in the public SDK):
//
//   View.applyTransientUpdate(int mode)   static — waveform for upcoming updates
//   View.clearTransientUpdate(boolean)    static — back to the system default
//   View.repaintEverything(int mode)      static — redraw the whole panel with a waveform
//   View#refreshScreen(int mode)          instance — refresh this view's rect
//
// Mode values are ViewUpdateHelper.UI_* constants read from the device's
// framework.jar (Tab Ultra C, Android 11): they combine an EINK_WAVEFORM_MODE_*
// with update/wait flags, e.g. UI_GC_MODE = GC16 | FULL | WAIT = 98.
//
// "Auto" mode is what makes a desktop usable on e-ink: while frames are arriving
// (typing, scrolling, moving windows) the panel runs a fast A2-class waveform, and
// once the picture settles it is redrawn once with a ghost-clearing REAGL pass, plus
// a full GC16 flash every few settles to wipe residual ghosting.
//
// Every call is best-effort: on non-Onyx devices (DC-1) the methods don't exist and
// this class does nothing.
package com.daylight.mirror

import android.os.Build
import android.util.Log
import android.view.View
import java.io.File
import java.lang.reflect.Method

class EinkController(private val view: View) {

    companion object {
        private const val TAG = "DaylightMirror"

        // android.onyx.ViewUpdateHelper.UI_* (values from the device framework)
        const val UI_DEFAULT_MODE = 5        // EINK_WAVEFORM_MODE_AUTO
        const val UI_GU_MODE = 2             // GC16 partial
        const val UI_GC_MODE = 98            // GC16 | FULL | WAIT — full flash, cleanest
        const val UI_REGAL_MODE = 6          // REAGL — ghost reduction without a flash
        const val UI_DU_MODE = 1             // DU — fast, 2-level
        const val UI_A2_QUALITY_MODE = 2308  // A2 with dithering — fast, keeps some greys
        const val UI_X_A2_MODE = 16777220    // Onyx "X" A2 — fastest

        // Mirrors EinkMode in Configuration.swift
        const val MODE_AUTO = 0
        const val MODE_QUALITY = 1
        const val MODE_BALANCED = 2
        const val MODE_FAST = 3

        /// After this long without a new frame, the picture counts as settled.
        const val SETTLE_MS = 450L
        /// Every Nth settle gets a full GC16 flash instead of a REAGL pass.
        const val FULL_REFRESH_EVERY = 8

        val isOnyx: Boolean =
            Build.MANUFACTURER.equals("ONYX", ignoreCase = true) ||
            Build.BRAND.equals("ONYX", ignoreCase = true) ||
            Build.PRODUCT.equals("BOOX", ignoreCase = true)

        private fun staticMethod(name: String, vararg types: Class<*>): Method? = try {
            View::class.java.getMethod(name, *types)
        } catch (t: Throwable) {
            null
        }

        private val mApplyTransient = staticMethod("applyTransientUpdate", Int::class.javaPrimitiveType!!)
        private val mClearTransient = staticMethod("clearTransientUpdate", Boolean::class.javaPrimitiveType!!)
        private val mRepaintEverything = staticMethod("repaintEverything", Int::class.javaPrimitiveType!!)
        private val mRefreshScreen = staticMethod("refreshScreen", Int::class.javaPrimitiveType!!)
    }

    val available: Boolean = isOnyx && mApplyTransient != null && mRepaintEverything != null

    private var mode = MODE_AUTO
    private var fastActive = false
    private var settles = 0

    init {
        Log.i(TAG, "EinkController: onyx=$isOnyx transient=${mApplyTransient != null} " +
            "repaint=${mRepaintEverything != null} refresh=${mRefreshScreen != null}")
    }

    /// Mode chosen on the Mac (EinkMode raw value).
    fun setMode(newMode: Int) {
        if (!available) return
        mode = newMode
        fastActive = false
        when (newMode) {
            MODE_QUALITY -> clearTransient()
            MODE_BALANCED -> applyTransient(UI_REGAL_MODE)
            MODE_FAST -> applyTransient(UI_X_A2_MODE)
            else -> clearTransient()  // auto: start in quality, onFrameActivity switches
        }
        Log.i(TAG, "E-ink mode → $newMode")
    }

    /// Called ~every 100 ms with the age of the newest frame (ms, -1 = none yet).
    fun onFrameAge(ageMs: Long) {
        if (!available || mode != MODE_AUTO || ageMs < 0) return
        if (ageMs < SETTLE_MS) {
            if (!fastActive) {
                fastActive = true
                applyTransient(UI_A2_QUALITY_MODE)
            }
        } else if (fastActive) {
            fastActive = false
            clearTransient()
            settles += 1
            // Redraw the settled picture with a clean waveform to erase A2 artifacts.
            repaint(if (settles % FULL_REFRESH_EVERY == 0) UI_GC_MODE else UI_REGAL_MODE)
        }
    }

    /// Full-panel GC16 flash (Ctrl+F5 on the Mac). `value` is reserved.
    fun fullRefresh() {
        if (!available) return
        repaint(UI_GC_MODE)
        settles = 0
    }

    // MARK: - Frontlight (Onyx sysfs, 0...max_brightness)

    fun setFrontlight(value255: Int) = writeLight("onyx_bl_br", value255)
    fun setWarmth(value255: Int) = writeLight("onyx_bl_ct", value255)

    // On most firmwares SELinux denies apps these nodes (EACCES) and the Mac writes them
    // over adb instead; try once, then stay quiet.
    @Volatile private var sysfsLightBlocked = false

    private fun writeLight(node: String, value255: Int) {
        if (sysfsLightBlocked) return
        Thread {
            try {
                val dir = File("/sys/class/backlight/$node")
                val max = File(dir, "max_brightness").readText().trim().toIntOrNull() ?: 32
                val scaled = (value255.coerceIn(0, 255) * max + 127) / 255
                File(dir, "brightness").writeText(scaled.toString())
            } catch (e: Exception) {
                if (!sysfsLightBlocked) Log.i(TAG, "Frontlight sysfs not writable by app (${e.message}); Mac drives it via adb")
                sysfsLightBlocked = true
            }
        }.start()
    }

    // MARK: - Reflection wrappers

    private fun applyTransient(uiMode: Int) = invoke(mApplyTransient, null, uiMode)
    private fun clearTransient() = invoke(mClearTransient, null, true)
    private fun repaint(uiMode: Int) {
        if (!invoke(mRepaintEverything, null, uiMode)) invoke(mRefreshScreen, view, uiMode)
    }

    private fun invoke(m: Method?, target: Any?, vararg args: Any): Boolean {
        if (m == null) return false
        return try {
            m.invoke(target, *args)
            true
        } catch (t: Throwable) {
            Log.w(TAG, "EPD call ${m.name} failed: ${t.cause ?: t}")
            false
        }
    }
}
