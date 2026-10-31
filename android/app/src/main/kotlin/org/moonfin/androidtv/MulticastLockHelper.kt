package org.moonfin.androidtv

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Holds a Wi-Fi multicast lock while Dart browses Bonjour for Lambent Server.
 * Without it many Android devices on Wi-Fi drop the mDNS answers before the
 * app's socket ever sees them.
 */
class MulticastLockHelper(context: Context) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL = "org.moonfin/multicast_lock"
    }

    private val wifi =
        context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
    private var lock: WifiManager.MulticastLock? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "acquire" -> {
                if (lock?.isHeld != true) {
                    lock = wifi?.createMulticastLock("lambent_server_discovery")?.apply {
                        setReferenceCounted(false)
                        acquire()
                    }
                }
                result.success(lock?.isHeld == true)
            }
            "release" -> {
                if (lock?.isHeld == true) lock?.release()
                lock = null
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}
