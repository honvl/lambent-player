package org.moonfin.nativevideo

import android.app.Activity
import android.hardware.display.DisplayManager
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.Display
import androidx.core.content.getSystemService
import java.lang.ref.WeakReference

/**
 * A display mode asked for the moment playback is requested, before the player
 * that will own it exists.
 *
 * The player can only pick a mode once the server has answered with the
 * stream, so a television that matches frame rates renegotiated a second or two
 * after the player had opened and blanked a screen that was already loading,
 * switching it into Dolby Vision on a Shield along the way. The title's own
 * streams carry the rate earlier, so the switch now runs as the player opens
 * and the player that follows takes the mode over ([claim]). Until then the
 * display and HDMI audio are watched, so the player knows when the television
 * last moved. A start that never claims it, failed or backed out of, hands the
 * display back on [release] or after [CLAIM_TIMEOUT_MS].
 */
internal object EarlyDisplayMode {
    private const val TAG = "MoonfinDisplayMode"
    private const val CLAIM_TIMEOUT_MS = 20_000L

    /** What the player adopts: the mode asked for, and the window's own from before. */
    class Request(
        val modeId: Int,
        val originalModeId: Int,
        val baseMode: DisplayModeOption,
        val changedPhysicalMode: Boolean,
        lastActivityAtMs: Long,
    ) {
        /** When the display or the HDMI audio route last changed since the request. */
        var lastActivityAtMs: Long = lastActivityAtMs
            internal set
    }

    private val handler = Handler(Looper.getMainLooper())
    private var pending: Request? = null
    private var pendingActivity: WeakReference<Activity>? = null
    private var displayListener: DisplayManager.DisplayListener? = null
    private var audioCallback: AudioDeviceCallback? = null
    private val expiry = Runnable { release("unclaimed") }

    /**
     * Points the window at the mode [frameRate] plays best on, the way the
     * player would with [behavior], and keeps it for the player. False when
     * nothing was asked for: switching is off, no mode fits, or the window
     * already prefers that mode.
     */
    fun request(
        activity: Activity,
        frameRate: Float,
        videoWidth: Int,
        videoHeight: Int,
        behavior: String,
    ): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        if (behavior != "scaleondevice" && behavior != "scaleontv") {
            Log.i(TAG, "frame rate switching is $behavior, nothing to ask for")
            return false
        }
        if (!frameRate.isFinite() || frameRate <= 0f) return false
        val window = activity.window ?: return false
        val display = activity.windowManager.defaultDisplay ?: return false
        val modes = display.supportedModes ?: return false
        val previous = pending
        // A second request before any player claimed the first chooses from
        // the viewer's mode, not from the one the first asked for.
        val base = previous?.baseMode ?: display.mode.toOption()
        val chosen = DisplayModeChooser.choose(
            modes = modes.map { it.toOption() },
            currentMode = base,
            contentFrameRate = DisplayModeChooser.normalizeFrameRate(frameRate),
            allowResolutionChange = behavior == "scaleontv",
            videoWidth = videoWidth,
            videoHeight = videoHeight,
        ) ?: return false
        val attributes = window.attributes
        val ownModeId = attributes.preferredDisplayModeId
        if (previous == null && ownModeId == chosen.modeId) {
            Log.i(TAG, "the window already asks for mode ${chosen.modeId}")
            return false
        }
        val changes = display.mode.modeId != chosen.modeId
        attributes.preferredDisplayModeId = chosen.modeId
        window.attributes = attributes
        pending = Request(
            modeId = chosen.modeId,
            originalModeId = previous?.originalModeId ?: ownModeId,
            baseMode = base,
            changedPhysicalMode = changes || previous?.changedPhysicalMode == true,
            lastActivityAtMs = SystemClock.elapsedRealtime(),
        )
        pendingActivity = WeakReference(activity)
        watch(activity)
        handler.removeCallbacks(expiry)
        handler.postDelayed(expiry, CLAIM_TIMEOUT_MS)
        Log.i(
            TAG,
            "asked for ${chosen.width}x${chosen.height}@${chosen.refreshRate} for $frameRate fps " +
                "before the player opened",
        )
        return true
    }

    /** The player taking the requested mode over, or null when nothing is pending. */
    fun claim(): Request? {
        val request = pending ?: return null
        clear()
        Log.i(TAG, "the player took over mode ${request.modeId}")
        return request
    }

    /** Hands the display back when no player took the requested mode over. */
    fun release(reason: String) {
        val request = pending ?: return
        val activity = pendingActivity?.get()
        clear()
        val window = activity?.window ?: return
        val attributes = window.attributes
        // Something else has pointed the window elsewhere since: leave it be.
        if (attributes.preferredDisplayModeId != request.modeId) return
        attributes.preferredDisplayModeId = request.originalModeId
        window.attributes = attributes
        Log.i(TAG, "handed the display back ($reason)")
    }

    private fun watch(activity: Activity) {
        if (displayListener == null) {
            val listener = object : DisplayManager.DisplayListener {
                override fun onDisplayAdded(displayId: Int) {}
                override fun onDisplayRemoved(displayId: Int) {}
                override fun onDisplayChanged(displayId: Int) = noteActivity()
            }
            activity.getSystemService<DisplayManager>()?.registerDisplayListener(listener, handler)
            displayListener = listener
        }
        if (audioCallback == null) {
            val callback = object : AudioDeviceCallback() {
                override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) {
                    if (addedDevices.any { isHdmi(it.type) }) noteActivity()
                }

                override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
                    if (removedDevices.any { isHdmi(it.type) }) noteActivity()
                }
            }
            activity.getSystemService<AudioManager>()?.registerAudioDeviceCallback(callback, handler)
            audioCallback = callback
        }
    }

    private fun noteActivity() {
        pending?.lastActivityAtMs = SystemClock.elapsedRealtime()
    }

    private fun clear() {
        handler.removeCallbacks(expiry)
        val activity = pendingActivity?.get()
        displayListener?.let { activity?.getSystemService<DisplayManager>()?.unregisterDisplayListener(it) }
        audioCallback?.let { activity?.getSystemService<AudioManager>()?.unregisterAudioDeviceCallback(it) }
        displayListener = null
        audioCallback = null
        pending = null
        pendingActivity = null
    }

    private fun isHdmi(type: Int): Boolean =
        type == AudioDeviceInfo.TYPE_HDMI ||
            type == AudioDeviceInfo.TYPE_HDMI_ARC ||
            (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && type == AudioDeviceInfo.TYPE_HDMI_EARC)

    private fun Display.Mode.toOption(): DisplayModeOption =
        DisplayModeOption(modeId, physicalWidth, physicalHeight, refreshRate)
}
