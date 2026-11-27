// MirrorActivity — minimal Activity that creates a SurfaceView and hands it to native code.
// All heavy lifting (socket, LZ4, delta, render) happens in C via JNI.
// Shows a status overlay when disconnected/reconnecting. Screen clears to white on disconnect.
package com.daylight.mirror

import android.animation.ObjectAnimator
import android.animation.ValueAnimator
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.Gravity
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowInsetsController
import android.view.WindowManager
import android.view.animation.AccelerateDecelerateInterpolator
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import java.io.OutputStream
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.LinkedBlockingQueue

class MirrorActivity : Activity() {

    companion object {
        init { System.loadLibrary("mirror") }

        // Touch input protocol constants — must match InputServer.swift
        const val INPUT_PORT = 8892
        const val REMOTE_PORT = 8893   // Mac's RemoteControlServer: STATUS / START <mode> / RELEASE
        const val INPUT_TOUCH_DOWN: Byte = 0x01
        const val INPUT_TOUCH_MOVE: Byte = 0x02
        const val INPUT_TOUCH_UP: Byte = 0x03
        const val INPUT_SCROLL: Byte = 0x04
        const val INPUT_KEY: Byte = 0x05     // [keycode:4][action:4][metaState:4][repeat:4][scanCode:4]
        val MAGIC_INPUT = byteArrayOf(0xDA.toByte(), 0x70.toByte())
    }

    private external fun nativeStart(surface: Surface, host: String, port: Int)
    private external fun nativeStop()
    private external fun nativeSetSurfaceSize(width: Int, height: Int)
    private external fun nativeLastFrameAgeMs(): Long
    private external fun nativeSetHosts(hosts: Array<String>)
    private external fun nativeSetToken(token: ByteArray)
    private external fun nativeSwitchToUSB()

    // MARK: - Wi-Fi: pairing + Mac discovery
    //
    // Over USB the stream arrives through the adb tunnel on 127.0.0.1. For Wi-Fi the Mac
    // hands over its addresses and a pairing secret whenever it launches this app over
    // USB (intent extras), and advertises itself via Bonjour (_daylight-mirror._tcp).
    // The native loop tries 127.0.0.1 first, then these hosts.
    private val prefs by lazy { getSharedPreferences("mirror", Context.MODE_PRIVATE) }
    private val discoveredHosts = linkedSetOf<String>()
    private var nsdManager: NsdManager? = null
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    private var resolving = false
    private val pendingResolves = ArrayDeque<NsdServiceInfo>()

    private val pairingToken: ByteArray?
        get() = prefs.getString("token", null)?.let { hex ->
            if (hex.length != 32) null
            else ByteArray(16) { i -> hex.substring(i * 2, i * 2 + 2).toInt(16).toByte() }
        }

    /// Store pairing details passed by the Mac (am start ... --es mirror_token/mirror_hosts).
    private fun applyPairingExtras(intent: Intent?) {
        val token = intent?.getStringExtra("mirror_token")
        val hosts = intent?.getStringExtra("mirror_hosts")
        if (token == null && hosts == null) return
        prefs.edit().apply {
            if (token != null && token.length == 32) putString("token", token.lowercase())
            if (hosts != null) putString("hosts", hosts)
        }.apply()
        android.util.Log.i("DaylightMirror", "Paired with Mac (hosts: ${hosts ?: "unchanged"})")
    }

    private fun candidateHosts(): Array<String> {
        val saved = prefs.getString("hosts", "")!!.split(",").map { it.trim() }.filter { it.isNotEmpty() }
        return (listOf("127.0.0.1") + saved + discoveredHosts).distinct().toTypedArray()
    }

    private fun pushConnectionConfig() {
        pairingToken?.let { nativeSetToken(it) }
        nativeSetHosts(candidateHosts())
    }

    private fun startDiscovery() {
        if (discoveryListener != null) return
        val mgr = getSystemService(Context.NSD_SERVICE) as? NsdManager ?: return
        nsdManager = mgr
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                android.util.Log.w("DaylightMirror", "Bonjour discovery failed: $errorCode")
                discoveryListener = null
            }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onServiceFound(info: NsdServiceInfo) {
                runOnUiThread { pendingResolves.addLast(info); resolveNext() }
            }
            override fun onServiceLost(info: NsdServiceInfo) {}
        }
        discoveryListener = listener
        try {
            mgr.discoverServices("_daylight-mirror._tcp", NsdManager.PROTOCOL_DNS_SD, listener)
        } catch (e: Exception) {
            android.util.Log.w("DaylightMirror", "Bonjour discovery unavailable: ${e.message}")
            discoveryListener = null
        }
    }

    /// NsdManager resolves one service at a time on this Android version.
    private fun resolveNext() {
        if (resolving) return
        val info = pendingResolves.removeFirstOrNull() ?: return
        val mgr = nsdManager ?: return
        resolving = true
        mgr.resolveService(info, object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                runOnUiThread { resolving = false; resolveNext() }
            }
            override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                val addr = serviceInfo.host?.hostAddress
                runOnUiThread {
                    resolving = false
                    if (addr != null && !addr.contains(":") && discoveredHosts.add(addr)) {
                        android.util.Log.i("DaylightMirror", "Found Mac via Bonjour: $addr")
                        pushConnectionConfig()
                        if (!isConnected && chooser.visibility == View.VISIBLE) handler.post(macPoll)
                    }
                    resolveNext()
                }
            }
        })
    }

    private fun stopDiscovery() {
        val l = discoveryListener ?: return
        try { nsdManager?.stopServiceDiscovery(l) } catch (_: Exception) {}
        discoveryListener = null
    }

    /// Called from native code once the stream connects; touch/keyboard follow it.
    @Suppress("unused")
    fun onConnectedHost(host: String) {
        runOnUiThread {
            handler.removeCallbacks(usbProbe)
            if (!host.startsWith("127.")) handler.postDelayed(usbProbe, 3000)
            if (touchSender?.host == host) return@runOnUiThread
            touchSender?.stop()
            touchSender = TouchSender(host, INPUT_PORT).also { it.start() }
        }
    }

    /// While streaming over Wi-Fi, check every 3 s whether the USB tunnel serves the stream
    /// (cable plugged in, or it came up after Wi-Fi won the race) and move to it.
    private val usbProbe = object : Runnable {
        override fun run() {
            if (!isConnected || touchSender?.host?.startsWith("127.") != false) return
            remoteExecutor.execute {
                val usbUp = try {
                    java.net.Socket().use { s ->
                        s.connect(java.net.InetSocketAddress("127.0.0.1", 8888), 300)
                        s.soTimeout = 1500
                        s.getInputStream().read() >= 0   // the Mac sends state on connect
                    }
                } catch (e: Exception) { false }
                runOnUiThread {
                    if (usbUp && isConnected) {
                        android.util.Log.i("DaylightMirror", "USB available — switching from Wi-Fi")
                        nativeSwitchToUSB()
                    } else {
                        handler.postDelayed(this, 3000)
                    }
                }
            }
        }
    }

    // MARK: - Find the Mac, then ask: Mirror or Second monitor?
    //
    // While no stream is connected, poll the Mac's remote-control port (USB tunnel first,
    // then Wi-Fi). If mirroring is stopped, show a chooser; the pick starts the Mac in that
    // mode, and the native loop then connects by itself. Leaving with Back tells the Mac
    // to stop (only if the BOOX started it).

    private val remoteExecutor = java.util.concurrent.Executors.newSingleThreadExecutor()
    @Volatile private var pollInFlight = false
    @Volatile private var macHost: String? = null
    private var macName = "your Mac"
    private var startingUntil = 0L
    private var lastKnownMode = "mirror"
    private lateinit var chooser: ChooserView
    private lateinit var settings: SettingsView
    /// Auto-start the remembered mode once per app open (never fight a stop from the Mac).
    private var autoStartArmed = true
    private val autoStart = Runnable { rememberedMode?.let { requestStart(it, auto = true) } }

    /// "Remember my choice": the mode to start automatically, or null to ask.
    private var rememberedMode: String?
        get() = prefs.getString("auto_mode", null)
        set(v) { prefs.edit().apply { if (v == null) remove("auto_mode") else putString("auto_mode", v) }.apply() }

    private val macPoll = object : Runnable {
        override fun run() {
            handler.removeCallbacks(this)
            if (isConnected) return
            pollMac()
            handler.postDelayed(this, 2000)
        }
    }

    private fun remoteHosts(): List<String> {
        val wifi = if (pairingToken != null) candidateHosts().filter { !it.startsWith("127.") } else emptyList()
        return (listOfNotNull(macHost) + "127.0.0.1" + wifi).distinct()
    }

    /// One request to the Mac's remote-control port; returns its reply line, or null.
    private fun sendRemote(host: String, command: String): String? {
        return try {
            java.net.Socket().use { s ->
                s.connect(java.net.InetSocketAddress(host, REMOTE_PORT), if (host.startsWith("127.")) 500 else 1500)
                s.soTimeout = 3000
                val out = s.getOutputStream()
                if (!host.startsWith("127.")) {
                    val token = pairingToken ?: return null
                    out.write(byteArrayOf(0xDA.toByte(), 0x75.toByte()) + token)
                }
                out.write((command + "\n").toByteArray())
                out.flush()
                s.getInputStream().bufferedReader().readLine()
            }
        } catch (e: Exception) {
            null
        }
    }

    private fun pollMac() {
        if (pollInFlight) return
        pollInFlight = true
        remoteExecutor.execute {
            var found: Pair<String, String>? = null
            for (h in remoteHosts()) {
                val reply = sendRemote(h, "STATUS")
                if (reply != null && reply.startsWith("OK ")) { found = h to reply; break }
            }
            pollInFlight = false
            runOnUiThread { onMacStatus(found) }
        }
    }

    /// STATUS reply: "OK <idle|starting|running|stopping|error> <mirror|extended> <Mac name>"
    private fun onMacStatus(found: Pair<String, String>?) {
        if (isConnected || isFinishing) return
        if (found == null) {
            macHost = null
            if (System.currentTimeMillis() < startingUntil) return
            showSearching()
            return
        }
        macHost = found.first
        val parts = found.second.split(" ", limit = 4)
        val state = parts.getOrNull(1) ?: "idle"
        val lastMode = parts.getOrNull(2) ?: "mirror"
        lastKnownMode = lastMode
        macName = parts.getOrNull(3)?.takeIf { it.isNotBlank() } ?: "your Mac"
        when (state) {
            "starting", "running", "stopping" ->
                if (System.currentTimeMillis() >= startingUntil) showOverlay("Connecting to $macName…", null)
            else -> {
                if (System.currentTimeMillis() < startingUntil) return
                val remembered = rememberedMode
                if (remembered != null && autoStartArmed) {
                    // Remembered choice: start it, with a moment to pick another
                    autoStartArmed = false
                    startingUntil = System.currentTimeMillis() + 22_000
                    chooser.showStarting(modeLabel(remembered), macName)
                    chooser.visibility = View.VISIBLE
                    handler.postDelayed(autoStart, 1500)
                } else {
                    chooser.showChooser(macName, lastMode, remembered != null)
                    chooser.visibility = View.VISIBLE
                }
            }
        }
    }

    private fun modeLabel(mode: String) = if (mode == "mirror") "mirroring" else "second monitor"

    private fun showOverlay(title: String, hint: String?) {
        chooser.showMessage(title, hint)
        chooser.visibility = View.VISIBLE
    }

    private fun showSearching() {
        if (pairingToken == null) {
            showOverlay("Looking for your Mac…",
                "Connect the USB cable and open Daylight Mirror on your Mac.\n" +
                    "After the first USB connection, Wi-Fi works too.")
        } else {
            showOverlay("Looking for your Mac…",
                "Plug in USB, or keep your Mac awake on the same Wi-Fi\n" +
                    "with Wireless turned on in Daylight Mirror.")
        }
    }

    /// Start the Mac in that mode; the stream connects on its own.
    private fun requestStart(mode: String, auto: Boolean = false) {
        val label = modeLabel(mode)
        startingUntil = System.currentTimeMillis() + 20_000
        if (!auto) {
            chooser.showStarting(label, macName)
            chooser.visibility = View.VISIBLE
        }
        remoteExecutor.execute {
            val reply = remoteHosts().firstNotNullOfOrNull { h -> sendRemote(h, "START $mode") }
            android.util.Log.i("DaylightMirror", "START $mode → ${reply ?: "no answer"}")
            if (reply == null || !reply.startsWith("OK")) {
                runOnUiThread {
                    startingUntil = 0
                    if (!isConnected) showOverlay("Couldn't start $label", reply ?: "Your Mac didn't answer.")
                }
            }
        }
    }

    /// Back pressed: tell the Mac we're done (it stops only if the BOOX started it).
    private fun releaseMac() {
        val hosts = remoteHosts()
        remoteExecutor.execute { hosts.firstNotNullOfOrNull { h -> sendRemote(h, "RELEASE") } }
    }

    override fun onPause() {
        super.onPause()
        if (isFinishing) releaseMac()
    }

    // MARK: - Settings panel (four-finger tap, or Settings on the chooser)

    private fun openSettings() {
        settings.showLoading()
        settings.visibility = View.VISIBLE
        loadSettings()
    }

    private fun closeSettings() {
        settings.visibility = View.GONE
    }

    private fun loadSettings() {
        val hosts = remoteHosts()
        remoteExecutor.execute {
            var found: Pair<String, String>? = null
            for (h in hosts) {
                val reply = sendRemote(h, "SETTINGS")
                if (reply != null && reply.startsWith("OK ")) { found = h to reply; break }
            }
            runOnUiThread {
                val (host, reply) = found ?: return@runOnUiThread settings.showUnavailable()
                macHost = host
                val map = reply.removePrefix("OK ").split(";").mapNotNull {
                    val i = it.indexOf('=')
                    if (i <= 0) null else it.substring(0, i) to it.substring(i + 1)
                }.toMap()
                val via = if ((touchSender?.host ?: host).startsWith("127.")) "USB" else "Wi-Fi"
                map["mode"]?.let { lastKnownMode = it }
                settings.update(map, macName, via, rememberedMode != null)
            }
        }
    }

    /// One SET to the Mac. Mode changes also update the remembered choice.
    private fun sendSetting(key: String, value: String) {
        if (key == "mode") {
            lastKnownMode = if (value == "extend") "extended" else value
            if (rememberedMode != null) rememberedMode = value
        }
        val hosts = remoteHosts()
        remoteExecutor.execute {
            val reply = hosts.firstNotNullOfOrNull { h -> sendRemote(h, "SET $key $value") }
            android.util.Log.i("DaylightMirror", "SET $key $value → ${reply ?: "no answer"}")
        }
    }

    private fun sendSimple(command: String) {
        val hosts = remoteHosts()
        remoteExecutor.execute { hosts.firstNotNullOfOrNull { h -> sendRemote(h, command) } }
    }

    @Deprecated("Back closes the settings panel first")
    override fun onBackPressed() {
        if (settings.visibility == View.VISIBLE) { closeSettings(); return }
        @Suppress("DEPRECATION")
        super.onBackPressed()
    }

    // Four-finger tap opens settings. 0 = normal input, 3 = three fingers down (held back
    // from the Mac), 4 = settings opened; reset when the last finger lifts.
    // Fires on the fourth finger landing, not on lift: the BOOX SystemUI grabs any quick
    // three-finger touch (its screenshot gesture) and cancels it in the app a few ms later,
    // so a tap that waited for the fingers to lift would never complete.
    private var multiFinger = 0

    private var pulseAnimator: ObjectAnimator? = null
    private val handler = Handler(Looper.getMainLooper())
    private var isConnected = false
    private var pendingDisconnect: Runnable? = null
    private var touchSender: TouchSender? = null
    private lateinit var eink: EinkController

    // Polls frame activity for the e-ink auto waveform (fast while moving, clean when settled)
    private val einkPoll = object : Runnable {
        override fun run() {
            eink.onFrameAge(nativeLastFrameAgeMs())
            handler.postDelayed(this, 100)
        }
    }

    // Previous touch position for computing scroll deltas
    private var prevScrollX = 0f
    private var prevScrollY = 0f

    // Frame size from the Mac — touches map through the same aspect-fit rect as the renderer
    @Volatile private var frameW = 0
    @Volatile private var frameH = 0

    /// Content rect (left, top, width, height) of the aspect-fitted frame inside the view.
    private fun contentRect(viewW: Int, viewH: Int): FloatArray {
        val fw = frameW.toFloat()
        val fh = frameH.toFloat()
        if (fw <= 0f || fh <= 0f || viewW <= 0 || viewH <= 0) {
            return floatArrayOf(0f, 0f, viewW.toFloat(), viewH.toFloat())
        }
        val scale = minOf(viewW / fw, viewH / fh)
        val cw = fw * scale
        val ch = fh * scale
        return floatArrayOf((viewW - cw) / 2f, (viewH - ch) / 2f, cw, ch)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        applyPairingExtras(intent)

        // Full immersive mode — hide ALL system UI to get the entire physical panel.
        // Uses modern WindowInsetsController API (API 30+). Without LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS,
        // Android reserves pixels for system bars even when hidden, causing resolution mismatch.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        window.attributes.layoutInDisplayCutoutMode =
            WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
        window.setDecorFitsSystemWindows(false)

        val frame = FrameLayout(this)

        val surfaceView = SurfaceView(this)
        eink = EinkController(surfaceView)
        frame.addView(surfaceView, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT
        ))

        // Status / mode chooser — shown while no stream is connected
        chooser = ChooserView(this).apply {
            onPick = { mode, remember ->
                rememberedMode = if (remember) mode else null
                requestStart(mode)
            }
            onChange = {
                handler.removeCallbacks(autoStart)
                autoStartArmed = false
                startingUntil = 0
                showChooser(macName, lastKnownMode, rememberedMode != null)
            }
            onSettings = { openSettings() }
        }
        frame.addView(chooser, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT
        ))

        settings = SettingsView(this).apply {
            visibility = View.GONE
            onSet = { key, value -> sendSetting(key, value) }
            onRefresh = { if (isConnected) eink.fullRefresh() else sendSimple("REFRESH") }
            onStop = {
                closeSettings()
                autoStartArmed = false  // don't immediately start again
                sendSimple("STOP")
            }
            onRememberChanged = { on ->
                rememberedMode = if (on) (if (lastKnownMode == "extended") "extend" else "mirror") else null
            }
            onClose = { closeSettings() }
        }
        frame.addView(settings, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT
        ))

        setContentView(frame)

        // WindowInsetsController must be called after setContentView (decorView exists now)
        window.insetsController?.let { controller ->
            controller.hide(android.view.WindowInsets.Type.systemBars())
            controller.systemBarsBehavior =
                WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }

        // Start pulsing the title immediately (waiting for first connection).
        // Not on e-ink: an endless alpha animation means endless panel refreshes.
        if (!EinkController.isOnyx) {
            pulseAnimator = ObjectAnimator.ofFloat(chooser.title, "alpha", 1f, 0.3f).apply {
                duration = 2000
                repeatMode = ValueAnimator.REVERSE
                repeatCount = ValueAnimator.INFINITE
                interpolator = AccelerateDecelerateInterpolator()
                start()
            }
        }

        // Touch input — capture taps, drags, and two-finger scrolls, send to Mac via InputServer
        surfaceView.setOnTouchListener { view, event ->
            val rect = contentRect(view.width, view.height)
            val normX = ((event.x - rect[0]) / rect[2]).coerceIn(0f, 1f)
            val normY = ((event.y - rect[1]) / rect[3]).coerceIn(0f, 1f)

            // Four-finger tap → settings, opened as soon as the fourth finger lands. From the
            // third finger on, nothing goes to the Mac (a zero scroll cancels the first
            // finger's pending click) until every finger is up.
            if (event.actionMasked == MotionEvent.ACTION_POINTER_DOWN && event.pointerCount >= 3) {
                if (multiFinger == 0) {
                    multiFinger = 3
                    sendTouchPacket(INPUT_SCROLL, normX, normY, 0f, 0f, 0)
                }
                if (event.pointerCount >= 4 && multiFinger == 3) {
                    multiFinger = 4
                    android.util.Log.i("DaylightMirror", "Four-finger tap — settings")
                    openSettings()
                }
                return@setOnTouchListener true
            }
            if (multiFinger > 0) {
                if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL) {
                    if (event.actionMasked == MotionEvent.ACTION_CANCEL) {
                        android.util.Log.i("DaylightMirror", "Multi-finger touch cancelled by the system")
                    }
                    multiFinger = 0
                    sendTouchPacket(INPUT_TOUCH_UP, normX, normY, 0f, 0f, 0)
                }
                return@setOnTouchListener true
            }

            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    prevScrollX = event.x
                    prevScrollY = event.y
                    sendTouchPacket(INPUT_TOUCH_DOWN, normX, normY, 0f, 0f, 0)
                }
                MotionEvent.ACTION_MOVE -> {
                    if (event.pointerCount >= 2) {
                        // Two-finger scroll: compute delta from previous position
                        val dx = (event.x - prevScrollX) / rect[2]
                        val dy = (event.y - prevScrollY) / rect[3]
                        prevScrollX = event.x
                        prevScrollY = event.y
                        sendTouchPacket(INPUT_SCROLL, normX, normY, dx, dy, 0)
                    } else {
                        sendTouchPacket(INPUT_TOUCH_MOVE, normX, normY, 0f, 0f, 0)
                    }
                }
                MotionEvent.ACTION_UP -> {
                    sendTouchPacket(INPUT_TOUCH_UP, normX, normY, 0f, 0f, 0)
                }
                MotionEvent.ACTION_CANCEL -> {
                    // The system took the touch (e.g. a BOOX gesture): end it without a click
                    sendTouchPacket(INPUT_SCROLL, normX, normY, 0f, 0f, 0)
                    sendTouchPacket(INPUT_TOUCH_UP, normX, normY, 0f, 0f, 0)
                }
                MotionEvent.ACTION_POINTER_DOWN -> {
                    // Second finger down — start scroll mode, reset delta tracking
                    prevScrollX = event.x
                    prevScrollY = event.y
                }
            }
            true
        }

        surfaceView.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                holder.surface.setFrameRate(if (EinkController.isOnyx) 30.0f else 60.0f,
                    Surface.FRAME_RATE_COMPATIBILITY_DEFAULT)
                pushConnectionConfig()
                nativeStart(holder.surface, "127.0.0.1", 8888)
                startDiscovery()
                autoStartArmed = true
                handler.postDelayed(macPoll, 300)
                if (eink.available) {
                    handler.removeCallbacks(einkPoll)
                    handler.post(einkPoll)
                }
                // Touch/keyboard sender starts in onConnectedHost(), aimed at whichever
                // host (USB tunnel or Wi-Fi) the stream reached.
            }

            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
                // Pass actual surface dimensions to native — this is the real
                // window size after any (or failed) orientation change.
                // Used to detect when the device claims landscape but the
                // surface is still physically portrait (e.g. Boox Palma).
                android.util.Log.i("DaylightMirror", "surfaceChanged: ${width}x${height}")
                nativeSetSurfaceSize(width, height)
            }

            override fun surfaceDestroyed(holder: SurfaceHolder) {
                handler.removeCallbacks(einkPoll)
                handler.removeCallbacks(macPoll)
                handler.removeCallbacks(autoStart)
                touchSender?.stop()
                touchSender = null
                nativeStop()
            }
        })
    }

    /// Called from native code when connection state changes.
    /// State machine with asymmetric debounce:
    ///   connected → disconnected: wait 2s before showing overlay (native reconnect loop is 1s)
    ///   disconnected → connected: hide overlay immediately
    ///   reconnecting: show minimal "Reconnecting..." (not the full "Waiting" screen)
    @Suppress("unused")
    fun onConnectionState(connected: Boolean) {
        runOnUiThread {
            if (connected) {
                // Cancel any pending disconnect — connection recovered
                pendingDisconnect?.let { handler.removeCallbacks(it) }
                pendingDisconnect = null
                if (!isConnected) {
                    isConnected = true
                    startingUntil = 0
                    handler.removeCallbacks(macPoll)
                    pulseAnimator?.cancel()
                    pulseAnimator = null
                    chooser.title.alpha = 1f
                    chooser.visibility = View.GONE
                }
            } else {
                if (isConnected && pendingDisconnect == null) {
                    // Wait 2s before showing overlay — native code reconnects every 1s,
                    // so transient disconnects are absorbed without any visual flicker.
                    pendingDisconnect = Runnable {
                        isConnected = false
                        pendingDisconnect = null
                        // Brief "Reconnecting…", then the Mac poll takes over (chooser if the
                        // Mac stopped, "Connecting…" if it's still streaming).
                        showOverlay("Reconnecting…", null)
                        handler.postDelayed(macPoll, 1000)
                        if (pulseAnimator == null && !EinkController.isOnyx) {
                            pulseAnimator = ObjectAnimator.ofFloat(chooser.title, "alpha", 1f, 0.3f).apply {
                                duration = 2000
                                repeatMode = ValueAnimator.REVERSE
                                repeatCount = ValueAnimator.INFINITE
                                interpolator = AccelerateDecelerateInterpolator()
                                start()
                            }
                        }
                    }
                    handler.postDelayed(pendingDisconnect!!, 2000)
                }
            }
        }
    }

    /// Called from native code when resolution changes and orientation needs updating.
    /// Portrait = h > w, landscape = w >= h.
    @Suppress("unused")
    fun setOrientation(portrait: Boolean) {
        runOnUiThread {
            requestedOrientation = if (portrait) {
                android.util.Log.i("DaylightMirror", "Switching to portrait orientation")
                ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            } else {
                android.util.Log.i("DaylightMirror", "Switching to landscape orientation")
                ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
            }
        }
    }

    /// Called from native code when a brightness command arrives.
    /// BOOX: drives the Onyx frontlight directly. DC-1: window brightness.
    @Suppress("unused")
    fun setBrightness(value: Int) {
        val clamped = value.coerceIn(0, 255)
        if (EinkController.isOnyx) {
            eink.setFrontlight(clamped)
            return
        }
        runOnUiThread {
            val lp = window.attributes
            lp.screenBrightness = clamped / 255f
            window.attributes = lp
        }
    }

    /// Called from native code when a warmth command arrives.
    @Suppress("unused")
    fun setWarmth(value: Int) {
        if (EinkController.isOnyx) {
            eink.setWarmth(value)
            return
        }
        val amberRate = (value.coerceIn(0, 255) * 1023) / 255
        runOnUiThread {
            try {
                Settings.System.putInt(contentResolver, "screen_brightness_amber_rate", amberRate)
            } catch (e: Exception) {
                android.util.Log.e("DaylightMirror", "Cannot set amber_rate: ${e.message}")
            }
        }
    }

    /// Called from native code when the Mac announces a frame size: (w << 16) | h.
    @Suppress("unused")
    fun onFrameSize(packed: Int) {
        frameW = (packed ushr 16) and 0xFFFF
        frameH = packed and 0xFFFF
    }

    /// Called from native code: full e-ink refresh (Ctrl+F5 on the Mac).
    @Suppress("unused")
    fun refreshScreen(@Suppress("UNUSED_PARAMETER") value: Int) {
        runOnUiThread { eink.fullRefresh() }
    }

    /// Called from native code: e-ink waveform preference (EinkMode raw value).
    @Suppress("unused")
    fun setEinkMode(value: Int) {
        runOnUiThread { eink.setMode(value) }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            // Re-hide system bars when focus returns (e.g. after a swipe gesture)
            window.insetsController?.let { controller ->
                controller.hide(android.view.WindowInsets.Type.systemBars())
                controller.systemBarsBehavior =
                    WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        }
    }

    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        applyPairingExtras(intent)
        pushConnectionConfig()
    }

    override fun onDestroy() {
        stopDiscovery()
        handler.removeCallbacks(macPoll)
        handler.removeCallbacks(usbProbe)
        remoteExecutor.shutdown()
        handler.removeCallbacks(einkPoll)
        touchSender?.stop()
        touchSender = null
        super.onDestroy()
    }

    /// Physical keyboard (BOOX keyboard cover, USB/Bluetooth) → Mac keystrokes.
    /// The Linux scan code (physical key position) is sent alongside the Android keycode:
    /// layout apps on the device (e.g. Full Colemak) remap keycodes, and applying the Mac's
    /// own layout on top would translate twice. The Mac prefers the scan code, so the cover
    /// behaves like a keyboard plugged into the Mac and only the Mac's layout applies.
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val device = event.device
        val fromKeyboard = device != null && !device.isVirtual &&
            (event.source and InputDevice.SOURCE_KEYBOARD) == InputDevice.SOURCE_KEYBOARD &&
            device.keyboardType == InputDevice.KEYBOARD_TYPE_ALPHABETIC
        val passThrough = when (event.keyCode) {
            KeyEvent.KEYCODE_VOLUME_UP, KeyEvent.KEYCODE_VOLUME_DOWN, KeyEvent.KEYCODE_VOLUME_MUTE,
            KeyEvent.KEYCODE_POWER, KeyEvent.KEYCODE_SLEEP, KeyEvent.KEYCODE_WAKEUP -> true
            else -> false
        }
        val sender = touchSender
        if (!fromKeyboard || passThrough || sender == null) return super.dispatchKeyEvent(event)
        val action = when (event.action) {
            KeyEvent.ACTION_DOWN -> 0
            KeyEvent.ACTION_UP -> 1
            else -> return true
        }
        val buf = ByteBuffer.allocate(23).order(ByteOrder.LITTLE_ENDIAN)
        buf.put(MAGIC_INPUT)
        buf.put(INPUT_KEY)
        buf.putInt(event.keyCode)
        buf.putInt(action)
        buf.putInt(event.metaState)
        buf.putInt(event.repeatCount)
        buf.putInt(event.scanCode)
        sender.send(buf.array())
        return true  // consumed: Esc/Tab/arrows must not act on the mirror app itself
    }

    /// Build and enqueue a 23-byte touch input packet for sending to the Mac.
    private fun sendTouchPacket(type: Byte, x: Float, y: Float, dx: Float, dy: Float, pointerId: Int) {
        val buf = ByteBuffer.allocate(23).order(ByteOrder.LITTLE_ENDIAN)
        buf.put(MAGIC_INPUT)
        buf.put(type)
        buf.putFloat(x)
        buf.putFloat(y)
        buf.putFloat(dx)
        buf.putFloat(dy)
        buf.putInt(pointerId)
        touchSender?.send(buf.array())
    }

    /// Background thread that maintains a TCP connection to the Mac's InputServer
    /// and drains a blocking queue of touch packets. Reconnects automatically on failure.
    inner class TouchSender(val host: String, private val port: Int) {
        private val queue = LinkedBlockingQueue<ByteArray>()
        @Volatile private var running = false
        private var thread: Thread? = null

        fun start() {
            running = true
            thread = Thread({
                while (running) {
                    var socket: Socket? = null
                    var output: OutputStream? = null
                    try {
                        socket = Socket()
                        socket.connect(java.net.InetSocketAddress(host, port), 2000)
                        socket.tcpNoDelay = true
                        output = socket.getOutputStream()
                        // Wi-Fi: prove pairing before any input packet (USB tunnel is trusted)
                        if (!host.startsWith("127.")) {
                            val token = pairingToken ?: throw IllegalStateException("not paired — connect USB once")
                            output.write(byteArrayOf(0xDA.toByte(), 0x75.toByte()) + token)
                            output.flush()
                        }
                        android.util.Log.i("DaylightMirror", "TouchSender connected to $host:$port")

                        while (running) {
                            val packet = queue.take()
                            output.write(packet)
                            output.flush()
                        }
                    } catch (e: InterruptedException) {
                        // stop() was called
                        break
                    } catch (e: Exception) {
                        android.util.Log.w("DaylightMirror", "TouchSender error: ${e.message}")
                        // Clear stale packets before reconnecting
                        queue.clear()
                    } finally {
                        try { output?.close() } catch (_: Exception) {}
                        try { socket?.close() } catch (_: Exception) {}
                    }
                    // Wait before reconnect attempt
                    if (running) {
                        try { Thread.sleep(1000) } catch (_: InterruptedException) { break }
                    }
                }
            }, "TouchSender").also { it.isDaemon = true }
            thread?.start()
        }

        fun send(packet: ByteArray) {
            if (running) queue.offer(packet)
        }

        fun stop() {
            running = false
            thread?.interrupt()
            thread = null
            queue.clear()
        }
    }
}
