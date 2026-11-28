package org.moonfin.nativevideo

import android.content.Context
import android.opengl.GLES30
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.util.GlUtil
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BaseGlShaderProgram
import androidx.media3.effect.GlEffect
import androidx.media3.effect.GlShaderProgram
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.floor
import kotlin.math.min

/**
 * Which titles RAVU-lite scales here (docs/SHADER_UPSCALE.md in Lambent): free for everyone, on any server, as on the Apple clients
 * (LambentClientUpscale.swift). SDR only: once effects are set every picture goes through Media3's graph, whose HDR input needs
 * EXT_YUV_target, which a Shield doesn't have. So an unknown range stays on the direct path too.
 */
internal object LambentUpscalePolicy {
    /** The shader's own condition: below this it would be scaled back down to nothing much (mpv's `//!WHEN`). */
    const val MINIMUM_SCALE = 1.41

    /** Up to here a title may be anamorphic, and the graph reports no pixel ratio to lay it out by, so it stays on the direct path. */
    const val STANDARD_DEFINITION_WIDTH = 854

    /** The picture's size on a [screenWidth] x [screenHeight] screen, in even pixels; null when it isn't worth scaling. */
    fun outputSize(width: Int, height: Int, screenWidth: Int, screenHeight: Int): Pair<Int, Int>? {
        if (width <= STANDARD_DEFINITION_WIDTH || height <= 0 || screenWidth <= 0 || screenHeight <= 0) return null
        val scale = min(screenWidth.toDouble() / width, screenHeight.toDouble() / height)
        if (scale < MINIMUM_SCALE) return null
        return Pair(floor(width * scale / 2).toInt() * 2, floor(height * scale / 2).toInt() * 2)
    }

    /**
     * A Lambent enhanced stream is the PC's picture: scaled here only when the plan asks (`cup`). A compare never asks.
     * [videoRangeType] is the title's range, so a stream the PC lifts to HDR (`hdr=1`) says so in its query instead.
     */
    fun applies(mediaType: String, preview: Boolean, videoRangeType: String?, url: String): Boolean {
        if (mediaType != "video" || preview || !videoRangeType.equals("SDR", ignoreCase = true)) return false
        if (!url.contains("/v1/enhanced/")) return true
        return Regex("[?&]cup=\\d").containsMatchIn(url) && !Regex("[?&]hdr=1(&|$)").containsMatchIn(url)
    }
}

/**
 * The title's own time between pictures, from the presentation times the effect sees: a low percentile of the last [WINDOW] gaps, so
 * pictures the player dropped before the effect (a gap of two or more) don't make the budget look looser than it is. A mean of the gaps
 * read 17-20 ms on a 59.94 fps title the Shield was dropping pictures of under r3 (2026-11-27), which kept r3 on.
 */
internal class LambentFrameInterval {
    private val gaps = FloatArray(WINDOW)
    private var count = 0
    private var next = 0

    /** 0 until [MINIMUM_GAPS] gaps are in. */
    var ms = 0f
        private set

    /** The gap since the last picture, in ms; a seek's or a stall's (over a second) and nonsense under 4 ms are not the title's. */
    fun add(gapMs: Float) {
        if (gapMs < 4f || gapMs >= 1000f) return
        gaps[next] = gapMs
        next = (next + 1) % WINDOW
        if (count < WINDOW) count++
        if (count < MINIMUM_GAPS) return
        val sorted = gaps.copyOf(count).also { it.sort() }
        ms = sorted[count / 10]
    }

    /** The gap is at least one picture missing. */
    fun isDrop(gapMs: Float) = ms > 0f && gapMs < 1000f && gapMs > ms * 1.5f

    companion object {
        const val WINDOW = 60
        const val MINIMUM_GAPS = 10
    }
}

/**
 * Which RAVU-lite runs, by the shader's own GPU time against the time between pictures, and by pictures dropped: r3 first, r2 where r3 doesn't keep up (a 2019
 * Shield at 60 fps: r3 11.5 ms a 1080p picture to 4K in Lambent's bench, r2 8.3), then plain scaling for the rest of the title, so the
 * upscaler never costs a dropped frame. r2 scores 0.2-0.3 VMAF NEG under r3, still 2-3 over bicubic (docs/SHADER_UPSCALE.md in Lambent).
 */
internal class LambentUpscaleLadder(private val radii: List<Int> = RADII) {
    private var step = 0
    private var frames = 0
    private var overBudget = 0

    /** The radius to draw with now; null once even the last is too slow. */
    val radius: Int? get() = radii.getOrNull(step)

    /** Over-budget count on the current radius, for the log. */
    val over: Int get() = overBudget

    /**
     * One timed picture, [ms] on the GPU against [intervalMs] (the title's, [LambentFrameInterval]), and whether any picture was
     * [dropped] since the last timed one; true when it moved down a step. A drop counts as over budget: the shader's own time leaves out
     * the decoder's and the compositor's on the same GPU (r3 13.4 ms against a 13.3 ms budget dropped pictures at 59.94 fps on a Shield).
     */
    fun timed(ms: Float, intervalMs: Float, dropped: Boolean = false): Boolean {
        if (radius == null) return false
        frames++
        // The clocks settle over the first pictures, on each step.
        if (frames <= WARM_UP_FRAMES || intervalMs <= 0f) return false
        overBudget = if (dropped || ms > intervalMs * BUDGET) overBudget + 1 else maxOf(0, overBudget - 1)
        if (overBudget < FALL_BACK_AFTER) return false
        step++
        frames = 0
        overBudget = 0
        return true
    }

    companion object {
        val RADII = listOf(3, 2)
        const val BUDGET = 0.8f
        const val WARM_UP_FRAMES = 30
        const val FALL_BACK_AFTER = 48
    }
}

/** RAVU-lite on the picture in Media3's graph: RGB to luma, the shader's two passes, then the luma merged into RGB at the output's size. */
@OptIn(UnstableApi::class)
internal class LambentUpscaleEffect(private val screenWidth: Int, private val screenHeight: Int) : GlEffect {
    override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram {
        check(!useHdr) { "RAVU-lite here is SDR only" }
        return Program(context)
    }

    internal class Target(width: Int, height: Int, internal: Int, format: Int, type: Int, filter: Int) {
        val texture = newTexture(filter).also {
            GLES30.glTexImage2D(GLES30.GL_TEXTURE_2D, 0, internal, width, height, 0, format, type, null)
        }
        val framebuffer = IntArray(1).also { GLES30.glGenFramebuffers(1, it, 0) }[0].also {
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, it)
            GLES30.glFramebufferTexture2D(GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0, GLES30.GL_TEXTURE_2D, texture, 0)
            check(GLES30.glCheckFramebufferStatus(GLES30.GL_FRAMEBUFFER) == GLES30.GL_FRAMEBUFFER_COMPLETE) { "framebuffer incomplete" }
        }

        fun release() {
            GLES30.glDeleteFramebuffers(1, intArrayOf(framebuffer), 0)
            GLES30.glDeleteTextures(1, intArrayOf(texture), 0)
        }
    }

    private inner class Program(context: Context) : BaseGlShaderProgram(/* useHighPrecisionColorComponents= */ false, /* texturePoolCapacity= */ 1) {
        // Each radius's programs compiled before the title starts, so a step down mid-play compiles nothing.
        private val ravus = LambentUpscaleLadder.RADII.associateWith { RavuLite(context, it) }
        private val ladder = LambentUpscaleLadder()
        private val merge = compile(MERGE)
        private val plain = compile(PLAIN)
        private val vertexArray = IntArray(1).also { GLES30.glGenVertexArrays(1, it, 0) }[0]
        private val query = IntArray(1).also { GLES30.glGenQueries(1, it, 0) }[0]
        private var queryPending = false
        private var width = 0
        private var height = 0
        private var scaling = false
        private var outputWidth = 0
        private var outputHeight = 0

        // Whether this GPU keeps up ([LambentUpscaleLadder]).
        private var lastPresentationUs = Long.MIN_VALUE
        private val interval = LambentFrameInterval()
        private var droppedSinceTimed = false
        private var windowFrames = 0
        private var windowMs = 0f
        private var windowMaxMs = 0f
        private var windowDrops = 0
        private var lastLog = 0L

        override fun configure(inputWidth: Int, inputHeight: Int): Size {
            width = inputWidth
            height = inputHeight
            val output = LambentUpscalePolicy.outputSize(inputWidth, inputHeight, screenWidth, screenHeight)
            outputWidth = output?.first ?: inputWidth
            outputHeight = output?.second ?: inputHeight
            scaling = output != null
            val radius = ladder.radius
            // Only the radius in use holds targets.
            ravus.forEach { (r, ravu) -> if (scaling && r == radius) ravu.configure(width, height) else ravu.releaseTargets() }
            Log.i(TAG, "${inputWidth}x$inputHeight to ${outputWidth}x$outputHeight, RAVU-lite ${if (output == null) "not needed" else if (radius == null) "off" else "r$radius"}")
            return Size(outputWidth, outputHeight)
        }

        override fun drawFrame(inputTexId: Int, presentationTimeUs: Long) {
            val bound = IntArray(1)
            GLES30.glGetIntegerv(GLES30.GL_FRAMEBUFFER_BINDING, bound, 0)
            val output = bound[0]
            GLES30.glBindVertexArray(vertexArray)
            readTiming(presentationTimeUs)
            val ravu = ladder.radius?.let { ravus.getValue(it) }
            if (!scaling || ravu == null) {
                RavuLite.draw(output, outputWidth, outputHeight, plain, "src" to inputTexId)
            } else {
                if (!queryPending) GLES30.glBeginQuery(TIME_ELAPSED, query)
                val timing = !queryPending
                val doubled = ravu.doubledLuma(inputTexId)
                GLES30.glBindVertexArray(vertexArray)
                RavuLite.draw(output, outputWidth, outputHeight, merge, "src" to inputTexId, "luma" to doubled)
                if (timing) {
                    GLES30.glEndQuery(TIME_ELAPSED)
                    queryPending = true
                }
            }
            GLES30.glBindVertexArray(0)
            GlUtil.checkGlError()
        }


        private fun readTiming(presentationTimeUs: Long) {
            if (lastPresentationUs != Long.MIN_VALUE) {
                val gap = (presentationTimeUs - lastPresentationUs) / 1000f
                if (interval.isDrop(gap)) droppedSinceTimed = true
                interval.add(gap)
            }
            lastPresentationUs = presentationTimeUs
            val intervalMs = interval.ms
            if (!queryPending) return
            val available = IntArray(1)
            GLES30.glGetQueryObjectuiv(query, GLES30.GL_QUERY_RESULT_AVAILABLE, available, 0)
            if (available[0] == 0) return
            val nanoseconds = IntArray(1)
            GLES30.glGetQueryObjectuiv(query, GLES30.GL_QUERY_RESULT, nanoseconds, 0)
            queryPending = false
            val ms = nanoseconds[0] / 1e6f
            windowFrames++
            windowMs += ms
            if (ms > windowMaxMs) windowMaxMs = ms
            val from = ladder.radius
            val dropped = droppedSinceTimed
            droppedSinceTimed = false
            if (dropped) windowDrops++
            if (ladder.timed(ms, intervalMs, dropped)) {
                ravus[from]?.releaseTargets()
                val to = ladder.radius
                if (to != null) ravus.getValue(to).configure(width, height)
                Log.w(TAG, "RAVU-lite r$from to ${to?.let { "r$it" } ?: "off"} for this title: %.2f ms a picture, %.1f ms between them".format(ms, intervalMs))
                // The next window is the new step's own.
                windowFrames = 0
                windowMs = 0f
                windowMaxMs = 0f
                windowDrops = 0
                return
            }
            val now = android.os.SystemClock.elapsedRealtime()
            if (now - lastLog >= 2000) {
                Log.i(TAG, "r%s frames %d gpu_ms mean %.2f max %.2f interval_ms %.1f drops %d over %d".format(ladder.radius ?: "-", windowFrames, windowMs / windowFrames, windowMaxMs, intervalMs, windowDrops, ladder.over))
                lastLog = now
                windowFrames = 0
                windowMs = 0f
                windowMaxMs = 0f
                windowDrops = 0
            }
        }

        override fun release() {
            super.release()
            ravus.values.forEach(RavuLite::release)
            listOf(merge, plain).forEach(GLES30::glDeleteProgram)
            GLES30.glDeleteVertexArrays(1, intArrayOf(vertexArray), 0)
            GLES30.glDeleteQueries(1, intArrayOf(query), 0)
        }
    }

    internal companion object {
        const val TAG = "LambentUpscale"
        const val TIME_ELAPSED = 0x88BF

        const val VERTEX = """#version 300 es
out vec2 v;
void main() {
  vec2 p = vec2(float((gl_VertexID & 1) * 4 - 1), float((gl_VertexID & 2) * 2 - 1));
  v = p * 0.5 + 0.5;
  gl_Position = vec4(p, 0.0, 1.0);
}
"""
        const val HEAD = """#version 300 es
precision highp float;
precision highp sampler2D;
in vec2 v;
out vec4 fragColor;
"""
        const val LUMA = HEAD + """uniform sampler2D src;
void main() { fragColor = vec4(dot(texture(src, v).rgb, vec3(0.2126, 0.7152, 0.0722)), 0.0, 0.0, 1.0); }
"""
        const val PLAIN = HEAD + """uniform sampler2D src;
void main() { fragColor = vec4(texture(src, v).rgb, 1.0); }
"""
        // The scaled luma replaces the bilinear picture's: RGB moved by the difference, so chroma stays the source's.
        const val MERGE = HEAD + """uniform sampler2D src;
uniform sampler2D luma;
void main() {
  vec3 c = texture(src, v).rgb;
  fragColor = vec4(clamp(c + (texture(luma, v).r - dot(c, vec3(0.2126, 0.7152, 0.0722))), 0.0, 1.0), 1.0);
}
"""

        fun newTexture(filter: Int): Int {
            val texture = IntArray(1).also { GLES30.glGenTextures(1, it, 0) }[0]
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, texture)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, filter)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, filter)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
            return texture
        }

        fun compile(fragment: String): Int {
            val program = GLES30.glCreateProgram()
            for ((type, source) in listOf(GLES30.GL_VERTEX_SHADER to VERTEX, GLES30.GL_FRAGMENT_SHADER to fragment)) {
                // The hook's translation asks for 3.20; nothing in it needs more than 3.00.
                val shader = GLES30.glCreateShader(type)
                GLES30.glShaderSource(shader, source.replace("#version 320 es", "#version 300 es"))
                GLES30.glCompileShader(shader)
                val ok = IntArray(1)
                GLES30.glGetShaderiv(shader, GLES30.GL_COMPILE_STATUS, ok, 0)
                check(ok[0] != 0) { GLES30.glGetShaderInfoLog(shader) }
                GLES30.glAttachShader(program, shader)
                GLES30.glDeleteShader(shader)
            }
            GLES30.glLinkProgram(program)
            val ok = IntArray(1)
            GLES30.glGetProgramiv(program, GLES30.GL_LINK_STATUS, ok, 0)
            check(ok[0] != 0) { GLES30.glGetProgramInfoLog(program) }
            return program
        }
    }
}

/**
 * RAVU-lite's luma passes (mpv's hook: the picture's luma, then step 1 and step 2, twice the size): shared by the free upscale above and
 * Lambent Auto HDR's renderer (LambentAutoHdr.kt), which merges the doubled luma under the picture's own chroma in its lift. Needs a
 * current GLES 3 context; [doubledLuma] draws with its own vertex array (the full-screen triangle) and leaves none bound.
 */
@OptIn(UnstableApi::class)
internal class RavuLite(context: Context, private val radius: Int = 3) {
    // r3's files keep their first names; r2's are ravu2_* (assets/lambent_ravu/NOTICE.txt).
    private val prefix = if (radius == 3) "lambent_ravu/ravu_" else "lambent_ravu/ravu${radius}_"
    private val luma = LambentUpscaleEffect.compile(LambentUpscaleEffect.LUMA)
    private val step1 = LambentUpscaleEffect.compile(context.assets.open("${prefix}step1.frag").use { String(it.readBytes()) })
    private val step2 = LambentUpscaleEffect.compile(context.assets.open("${prefix}step2.frag").use { String(it.readBytes()) })
    private val vertexArray = IntArray(1).also { GLES30.glGenVertexArrays(1, it, 0) }[0]
    private val lut = LambentUpscaleEffect.newTexture(GLES30.GL_NEAREST).also {
        val bytes = context.assets.open("lambent_ravu/ravu_lut$radius.bin").use { input -> input.readBytes() }
        val data = ByteBuffer.allocateDirect(bytes.size).order(ByteOrder.nativeOrder()).put(bytes)
        data.position(0)
        // On disk the shader's 32-bit floats, as mpv's hook has them.
        // 288 rows of RGBA, as wide as the hook's //!SIZE says for its radius (r2 5, r3 13).
        val lutWidth = bytes.size / (288 * 16)
        GLES30.glTexImage2D(GLES30.GL_TEXTURE_2D, 0, GLES30.GL_RGBA16F, lutWidth, 288, 0, GLES30.GL_RGBA, GLES30.GL_FLOAT, data)
    }
    private var width = 0
    private var height = 0
    private var lumaTarget: LambentUpscaleEffect.Target? = null
    private var workTarget: LambentUpscaleEffect.Target? = null
    private var doubledTarget: LambentUpscaleEffect.Target? = null

    /** For a `w` x `h` picture (its targets made again only when the size changes). */
    fun configure(w: Int, h: Int) {
        if (w == width && h == height && doubledTarget != null) return
        releaseTargets()
        width = w
        height = h
        lumaTarget = LambentUpscaleEffect.Target(w, h, GLES30.GL_R16F, GLES30.GL_RED, GLES30.GL_HALF_FLOAT, GLES30.GL_NEAREST)
        workTarget = LambentUpscaleEffect.Target(w, h, GLES30.GL_RGBA16F, GLES30.GL_RGBA, GLES30.GL_HALF_FLOAT, GLES30.GL_NEAREST)
        doubledTarget = LambentUpscaleEffect.Target(w * 2, h * 2, GLES30.GL_R16F, GLES30.GL_RED, GLES30.GL_HALF_FLOAT, GLES30.GL_LINEAR)
    }

    /** `src` (an RGB 2D texture of the configured size, rows bottom-up as GL keeps them) to its luma at twice the size: that texture. */
    fun doubledLuma(src: Int): Int {
        val lumaPass = checkNotNull(lumaTarget)
        val work = checkNotNull(workTarget)
        val doubled = checkNotNull(doubledTarget)
        GLES30.glBindVertexArray(vertexArray)
        draw(lumaPass.framebuffer, width, height, luma, "src" to src)
        sizes(step1)
        draw(work.framebuffer, width, height, step1, "HOOKED" to lumaPass.texture, "ravu_lite_lut$radius" to lut)
        sizes(step2)
        draw(doubled.framebuffer, width * 2, height * 2, step2, "HOOKED" to lumaPass.texture, "ravu_lite_int" to work.texture)
        GLES30.glBindVertexArray(0)
        return doubled.texture
    }

    private fun sizes(program: Int) {
        GLES30.glUseProgram(program)
        GLES30.glUniform2f(GLES30.glGetUniformLocation(program, "HOOKED_size"), width.toFloat(), height.toFloat())
        GLES30.glUniform2f(GLES30.glGetUniformLocation(program, "HOOKED_pt"), 1f / width, 1f / height)
    }

    fun releaseTargets() {
        lumaTarget?.release()
        workTarget?.release()
        doubledTarget?.release()
        lumaTarget = null
        workTarget = null
        doubledTarget = null
        width = 0
        height = 0
    }

    fun release() {
        releaseTargets()
        GLES30.glDeleteTextures(1, intArrayOf(lut), 0)
        listOf(luma, step1, step2).forEach(GLES30::glDeleteProgram)
        GLES30.glDeleteVertexArrays(1, intArrayOf(vertexArray), 0)
    }

    companion object {
        /** A pass of the full-screen triangle into `framebuffer`, `textures` on units 0, 1 ... by their uniform names. */
        fun draw(framebuffer: Int, w: Int, h: Int, program: Int, vararg textures: Pair<String, Int>) {
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, framebuffer)
            GLES30.glViewport(0, 0, w, h)
            GLES30.glUseProgram(program)
            textures.forEachIndexed { unit, (name, texture) ->
                GLES30.glActiveTexture(GLES30.GL_TEXTURE0 + unit)
                GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, texture)
                GLES30.glUniform1i(GLES30.glGetUniformLocation(program, name), unit)
            }
            GLES30.glDrawArrays(GLES30.GL_TRIANGLES, 0, 3)
            GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        }
    }
}
