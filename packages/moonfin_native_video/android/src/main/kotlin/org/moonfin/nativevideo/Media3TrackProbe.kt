package org.moonfin.nativevideo

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.MetadataRetriever
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/**
 * Reads a local file's tracks the way the Media3 player will see them, for a
 * file that no server describes (one opened from the device's own storage).
 *
 * The answer is in the shape of a Jellyfin item's MediaStreams. The player
 * picks a track by its 1-based position among the tracks of its type in the
 * order the source declared them, so the streams here keep that order, and
 * each gets the position of its group in the file as its index.
 */
@UnstableApi
object Media3TrackProbe {
    const val CHANNEL = "moonfin/media3_probe"

    private val main = Handler(Looper.getMainLooper())

    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, context: Context?) {
        if (context == null) {
            result.success(null)
            return
        }
        if (call.method != "probe") {
            result.notImplemented()
            return
        }
        val url = call.argument<String>("url")
        if (url.isNullOrEmpty()) {
            result.error("args", "url missing", null)
            return
        }
        thread(name = "moonfin-track-probe") {
            val probed = try {
                probe(context, url)
            } catch (_: Throwable) {
                null
            }
            main.post { result.success(probed) }
        }
    }

    private fun probe(context: Context, url: String): Map<String, Any?>? {
        val parsed = Uri.parse(url)
        val uri = if (parsed.scheme.isNullOrEmpty()) Uri.fromFile(File(url)) else parsed
        MetadataRetriever.Builder(context.applicationContext, MediaItem.fromUri(uri)).build().use { retriever ->
            val groups = retriever.retrieveTrackGroups().get(20, TimeUnit.SECONDS)
            val durationUs = try {
                retriever.retrieveDurationUs().get(5, TimeUnit.SECONDS)
            } catch (_: Throwable) {
                C.TIME_UNSET
            }
            val streams = mutableListOf<Map<String, Any?>>()
            for (index in 0 until groups.length) {
                val group = groups[index]
                if (group.length == 0) continue
                val format = group.getFormat(0)
                stream(index, group.type, format)?.let(streams::add)
            }
            return mapOf(
                "MediaStreams" to streams,
                "RunTimeTicks" to if (durationUs != C.TIME_UNSET && durationUs > 0) durationUs * 10 else null,
            )
        }
    }

    private fun stream(index: Int, trackType: Int, format: Format): Map<String, Any?>? {
        val type = when (trackType) {
            C.TRACK_TYPE_VIDEO -> "Video"
            C.TRACK_TYPE_AUDIO -> "Audio"
            C.TRACK_TYPE_TEXT -> "Subtitle"
            else -> return null
        }
        // Media3 parses subtitles while extracting and hands them on as its own
        // cues, keeping the file's subtitle format in codecs.
        val mime = if (format.sampleMimeType == MimeTypes.APPLICATION_MEDIA3_CUES) {
            format.codecs ?: format.sampleMimeType
        } else {
            format.sampleMimeType ?: format.containerMimeType
        }
        val codec = codecName(mime)
        val language = format.language?.takeUnless { it == "und" || it.isBlank() }
        val stream = mutableMapOf<String, Any?>(
            "Index" to index,
            "Type" to type,
            "Codec" to codec,
            "IsDefault" to (format.selectionFlags and C.SELECTION_FLAG_DEFAULT != 0),
            "IsForced" to (format.selectionFlags and C.SELECTION_FLAG_FORCED != 0),
            "IsHearingImpaired" to (format.roleFlags and C.ROLE_FLAG_DESCRIBES_MUSIC_AND_SOUND != 0),
            "IsExternal" to false,
        )
        if (language != null) stream["Language"] = language
        format.label?.takeUnless { it.isBlank() }?.let { stream["Title"] = it }
        when (trackType) {
            C.TRACK_TYPE_VIDEO -> {
                if (format.width > 0) stream["Width"] = format.width
                if (format.height > 0) stream["Height"] = format.height
                if (format.frameRate > 0) {
                    stream["RealFrameRate"] = format.frameRate.toDouble()
                    stream["AverageFrameRate"] = format.frameRate.toDouble()
                }
                val hdr = format.colorInfo?.colorTransfer == C.COLOR_TRANSFER_ST2084 ||
                    format.colorInfo?.colorTransfer == C.COLOR_TRANSFER_HLG
                val rangeType = when {
                    mime == MimeTypes.VIDEO_DOLBY_VISION -> "DOVI"
                    format.colorInfo?.colorTransfer == C.COLOR_TRANSFER_HLG -> "HLG"
                    hdr -> "HDR10"
                    else -> "SDR"
                }
                stream["VideoRange"] = if (rangeType == "SDR") "SDR" else "HDR"
                stream["VideoRangeType"] = rangeType
                stream["DisplayTitle"] = listOfNotNull(
                    resolution(format.height),
                    rangeType.takeUnless { it == "SDR" },
                    codec.uppercase(),
                ).joinToString(" ")
            }
            C.TRACK_TYPE_AUDIO -> {
                if (format.channelCount > 0) stream["Channels"] = format.channelCount
                if (format.sampleRate > 0) stream["SampleRate"] = format.sampleRate
                if (format.bitrate > 0) stream["BitRate"] = format.bitrate
                stream["DisplayTitle"] = displayTitle(language, format.label, listOf(codec.uppercase(), channels(format.channelCount)))
            }
            C.TRACK_TYPE_TEXT -> {
                stream["IsTextSubtitleStream"] = codec in textCodecs
                stream["DeliveryMethod"] = "Embed"
                stream["DisplayTitle"] = displayTitle(language, format.label, listOf(codec.uppercase()))
            }
        }
        return stream
    }

    private val textCodecs = setOf("subrip", "ass", "ssa", "webvtt", "mov_text", "ttml")

    /** Jellyfin's (FFmpeg's) codec names for Media3's MIME types. */
    private fun codecName(mime: String?): String = when (mime) {
        MimeTypes.VIDEO_H264 -> "h264"
        MimeTypes.VIDEO_H265 -> "hevc"
        MimeTypes.VIDEO_AV1 -> "av1"
        MimeTypes.VIDEO_VP9 -> "vp9"
        MimeTypes.VIDEO_VP8 -> "vp8"
        MimeTypes.VIDEO_MPEG2 -> "mpeg2video"
        MimeTypes.VIDEO_DOLBY_VISION -> "hevc"
        MimeTypes.AUDIO_AAC -> "aac"
        MimeTypes.AUDIO_AC3 -> "ac3"
        MimeTypes.AUDIO_E_AC3, MimeTypes.AUDIO_E_AC3_JOC -> "eac3"
        MimeTypes.AUDIO_TRUEHD -> "truehd"
        MimeTypes.AUDIO_DTS, MimeTypes.AUDIO_DTS_HD, MimeTypes.AUDIO_DTS_EXPRESS -> "dts"
        MimeTypes.AUDIO_OPUS -> "opus"
        MimeTypes.AUDIO_FLAC -> "flac"
        MimeTypes.AUDIO_MPEG -> "mp3"
        MimeTypes.AUDIO_VORBIS -> "vorbis"
        MimeTypes.AUDIO_RAW -> "pcm"
        MimeTypes.APPLICATION_SUBRIP -> "subrip"
        MimeTypes.TEXT_SSA -> "ass"
        MimeTypes.TEXT_VTT -> "webvtt"
        MimeTypes.APPLICATION_TX3G -> "mov_text"
        MimeTypes.APPLICATION_TTML -> "ttml"
        MimeTypes.APPLICATION_PGS -> "pgssub"
        MimeTypes.APPLICATION_VOBSUB -> "dvdsub"
        MimeTypes.APPLICATION_DVBSUBS -> "dvbsub"
        else -> mime?.substringAfter('/')?.removePrefix("x-") ?: ""
    }

    private fun resolution(height: Int): String? = when {
        height <= 0 -> null
        height >= 2000 -> "4K"
        height >= 1000 -> "1080p"
        height >= 700 -> "720p"
        else -> "${height}p"
    }

    private fun channels(count: Int): String = when (count) {
        0 -> ""
        1 -> "Mono"
        2 -> "Stereo"
        6 -> "5.1"
        8 -> "7.1"
        else -> "${count}ch"
    }

    private fun displayTitle(language: String?, label: String?, detail: List<String>): String {
        val name = language?.let { java.util.Locale.forLanguageTag(it).getDisplayLanguage(java.util.Locale.getDefault()).ifBlank { null } }
            ?: label?.takeUnless { it.isBlank() }
        return (listOfNotNull(name) + detail.filter { it.isNotBlank() }).joinToString(" - ")
    }
}
