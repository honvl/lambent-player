package org.moonfin.androidtv

import android.app.Activity
import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Video files on this device outside the app's downloads: picked in the system
 * file browser, or handed over with "Open with" from a file manager.
 *
 * A file stays where it is. A picked file keeps a persistable read grant, so
 * its content:// address opens again after a restart; the address is what
 * Dart stores as the file's bookmark and what the Media3 player plays.
 */
class LocalFileChannel(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL = "org.moonfin/local_files"
        const val PICK_REQUEST = 47101
    }

    private val channel = MethodChannel(messenger, CHANNEL).also { it.setMethodCallHandler(this) }
    private var pickResult: MethodChannel.Result? = null

    /** Files handed over before Dart asked for them. */
    private val pending = mutableListOf<Map<String, Any?>>()

    private val resolver: ContentResolver get() = activity.contentResolver

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pick" -> pick(result)
            "open" -> result.success(open(call.argument<ByteArray>("bookmark")))
            // A persistable grant needs no holding open between plays.
            "release" -> result.success(null)
            "forget" -> {
                forget(call.argument<ByteArray>("bookmark"))
                result.success(null)
            }
            "takePending" -> {
                result.success(ArrayList(pending))
                pending.clear()
            }
            else -> result.notImplemented()
        }
    }

    private fun pick(result: MethodChannel.Result) {
        if (pickResult != null) {
            result.error("busy", "a picker is already open", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "video/*"
            // Matroska often comes without a video/ type from the provider.
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf("video/*", "application/x-matroska", "video/x-matroska"),
            )
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        pickResult = result
        try {
            activity.startActivityForResult(intent, PICK_REQUEST)
        } catch (_: Exception) {
            pickResult = null
            result.error("no_picker", "no file browser on this device", null)
        }
    }

    /** Returns true when [requestCode] was the picker's. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICK_REQUEST) return false
        val result = pickResult ?: return true
        pickResult = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(emptyList<Map<String, Any?>>())
            return true
        }
        try {
            resolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } catch (_: SecurityException) {
            // The provider offers no lasting grant; the file still plays now.
        }
        result.success(listOfNotNull(describe(uri, owned = false)))
        return true
    }

    /**
     * A video handed over with "Open with". Returns true when [intent] was one,
     * so the activity doesn't pass it on as a deep link.
     */
    fun receive(intent: Intent?): Boolean {
        if (intent?.action != Intent.ACTION_VIEW) return false
        val uri = intent.data ?: return false
        if (uri.scheme != ContentResolver.SCHEME_CONTENT && uri.scheme != ContentResolver.SCHEME_FILE) return false
        val type = intent.type ?: resolver.getType(uri)
        if (type != null && !type.startsWith("video/") && type != "application/x-matroska") return false
        // Usually only a grant for now; when the provider allows it, keep it.
        if (intent.flags and Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION != 0) {
            try {
                resolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            } catch (_: SecurityException) {}
        }
        val file = describe(uri, owned = false) ?: return false
        pending.add(file)
        channel.invokeMethod("incoming", null)
        return true
    }

    private fun describe(uri: Uri, owned: Boolean): Map<String, Any?>? {
        var name: String? = null
        var size = 0L
        if (uri.scheme == ContentResolver.SCHEME_FILE) {
            val file = File(uri.path ?: return null)
            name = file.name
            size = file.length()
        } else {
            try {
                resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)
                    ?.use { cursor ->
                        if (cursor.moveToFirst()) {
                            val nameColumn = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                            val sizeColumn = cursor.getColumnIndex(OpenableColumns.SIZE)
                            if (nameColumn >= 0) name = cursor.getString(nameColumn)
                            if (sizeColumn >= 0 && !cursor.isNull(sizeColumn)) size = cursor.getLong(sizeColumn)
                        }
                    }
            } catch (_: Exception) {
                return null
            }
        }
        return mapOf(
            "bookmark" to uri.toString().toByteArray(),
            "name" to (name ?: uri.lastPathSegment ?: "Video"),
            "path" to uri.toString(),
            "size" to size,
            "owned" to owned,
        )
    }

    /** The file's address when it can still be read, for the player. */
    private fun open(bookmark: ByteArray?): Map<String, Any?>? {
        val uri = bookmark?.let { Uri.parse(String(it)) } ?: return null
        return try {
            if (uri.scheme == ContentResolver.SCHEME_FILE) {
                if (!File(uri.path ?: return null).canRead()) return null
            } else {
                resolver.openFileDescriptor(uri, "r")?.close() ?: return null
            }
            mapOf("path" to uri.toString())
        } catch (_: Exception) {
            null
        }
    }

    private fun forget(bookmark: ByteArray?) {
        val uri = bookmark?.let { Uri.parse(String(it)) } ?: return
        try {
            resolver.releasePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } catch (_: Exception) {}
    }
}
