package org.moonfin.nativevideo

import android.net.Uri
import android.util.Log
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import io.github.peerless2012.ass.AssTrack
import io.github.peerless2012.ass.media.AssHandler
import java.io.ByteArrayOutputStream
import java.util.concurrent.atomic.AtomicLong

/**
 * Lambent Server sends an ASS track inside the enhanced title as a script
 * header only (`.../Subtitles/{n}/0/Live.ass`): the whole script would wait
 * for a read of the whole episode. The events come from
 * `.../Live/events?from=&to=` as the PC's enhancer reads the file, one a
 * line as `start ms,duration ms,` and the Matroska block, after a first line
 * `; covered` or `; partial`. This feeds them to the libass track ass-media
 * made from the header, in 10 s windows from the playhead, the way the
 * Matroska extractor feeds an embedded track (libass drops a block whose
 * ReadOrder it has already).
 */
class LiveAssFeeder(
    private val assHandler: AssHandler,
    private val dataSources: DataSource.Factory,
    private val onEvents: () -> Unit,
) {
    private val positionMs = AtomicLong(0L)
    @Volatile private var eventsBase: String? = null
    @Volatile private var thread: Thread? = null

    /** Called on the player thread: the playhead the next windows follow. */
    fun updatePosition(ms: Long) {
        positionMs.set(ms.coerceAtLeast(0L))
    }

    /** The selected text track's URL, or null: starts or stops feeding. */
    fun follow(subtitleUri: Uri?) {
        val base = subtitleUri?.let(::eventsUrlBase)
        if (base == eventsBase) return
        eventsBase = base
        thread?.interrupt()
        thread = null
        if (base == null) return
        thread = Thread({ run(base) }, "moonfin-live-ass").apply {
            isDaemon = true
            start()
        }
    }

    fun stop() = follow(null)

    private fun run(base: String) {
        val done = HashSet<Long>()
        var fedTrack: AssTrack? = null
        while (eventsBase == base && !Thread.currentThread().isInterrupted) {
            val track = synchronized(assHandler) { assHandler.track }
            if (track !== fedTrack) {
                // A new libass track (the selection was made again) has none of the events.
                done.clear()
                fedTrack = track
            }
            if (track != null) {
                val first = (positionMs.get() - 1000L).coerceAtLeast(0L) / WINDOW_MS * WINDOW_MS
                for (step in 0 until WINDOWS_AHEAD) {
                    val from = first + step * WINDOW_MS
                    if (from in done) continue
                    // The window being shown waits for the reader; the ones ahead only look.
                    val result = fetch(base, from, if (step == 0) 3000 else 300) ?: break
                    if (eventsBase != base) return
                    feed(track, result.second)
                    if (!result.first) break
                    done.add(from)
                }
            }
            try {
                Thread.sleep(TICK_MS)
            } catch (_: InterruptedException) {
                return
            }
        }
    }

    /** One window: whether the reading has passed it, and its lines. */
    private fun fetch(base: String, fromMs: Long, waitMs: Int): Pair<Boolean, List<String>>? {
        val query = base.substringAfter('?', "")
        val url = "${base.substringBefore('?')}?from=${fromMs / 1000.0}&to=${(fromMs + WINDOW_MS) / 1000.0}" +
            "&wait=$waitMs" + if (query.isEmpty()) "" else "&$query"
        val source = dataSources.createDataSource()
        return try {
            source.open(DataSpec(Uri.parse(url)))
            val out = ByteArrayOutputStream()
            val buffer = ByteArray(16 * 1024)
            while (true) {
                val read = source.read(buffer, 0, buffer.size)
                if (read < 0) break
                out.write(buffer, 0, read)
            }
            val lines = out.toString(Charsets.UTF_8.name()).lines()
            Pair(lines.firstOrNull()?.trim() == "; covered", lines.drop(1))
        } catch (e: Exception) {
            Log.d(TAG, "live ASS window ${fromMs / 1000}s: ${e.message}")
            null
        } finally {
            runCatching { source.close() }
        }
    }

    private fun feed(track: AssTrack, lines: List<String>) {
        var fed = 0
        synchronized(assHandler) {
            if (assHandler.track !== track) return
            for (line in lines) {
                val first = line.indexOf(',')
                val second = if (first > 0) line.indexOf(',', first + 1) else -1
                if (second < 0) continue
                val start = line.substring(0, first).toLongOrNull() ?: continue
                val duration = line.substring(first + 1, second).toLongOrNull() ?: continue
                val block = line.substring(second + 1).toByteArray(Charsets.UTF_8)
                track.readChunk(start, duration, block, 0, block.size)
                fed++
            }
        }
        if (fed > 0) onEvents()
    }

    companion object {
        private const val TAG = "LiveAssFeeder"
        private const val WINDOW_MS = 10_000L
        private const val WINDOWS_AHEAD = 4
        private const val TICK_MS = 1000L

        /** `.../Subtitles/{n}/0/Live.ass?q` as `.../Subtitles/{n}/0/Live/events?q`, or null for any other subtitle. */
        fun eventsUrlBase(uri: Uri): String? {
            val text = uri.toString()
            val path = text.substringBefore('?')
            if (!path.endsWith("/Live.ass")) return null
            val query = text.substringAfter('?', "")
            return path.removeSuffix(".ass") + "/events" + if (query.isEmpty()) "" else "?$query"
        }
    }
}
