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

/** RAVU-lite on the picture in Media3's graph: RGB to luma, the shader's two passes, then the luma merged into RGB at the output's size. */
@OptIn(UnstableApi::class)
internal class LambentUpscaleEffect(private val screenWidth: Int, private val screenHeight: Int) : GlEffect {
    override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram {
        check(!useHdr) { "RAVU-lite here is SDR only" }
        return Program(context)
    }

    private class Target(width: Int, height: Int, internal: Int, format: Int, type: Int, filter: Int) {
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
        private val luma = compile(LUMA)
        private val step1 = compile(context.assets.open("lambent_ravu/ravu_step1.frag").use { String(it.readBytes()) })
        private val step2 = compile(context.assets.open("lambent_ravu/ravu_step2.frag").use { String(it.readBytes()) })
        private val merge = compile(MERGE)
        private val plain = compile(PLAIN)
        private val vertexArray = IntArray(1).also { GLES30.glGenVertexArrays(1, it, 0) }[0]
        private val query = IntArray(1).also { GLES30.glGenQueries(1, it, 0) }[0]
        private var queryPending = false
        private val lut = newTexture(GLES30.GL_NEAREST).also {
            val bytes = context.assets.open("lambent_ravu/ravu_lut3.bin").use { input -> input.readBytes() }
            val data = ByteBuffer.allocateDirect(bytes.size).order(ByteOrder.nativeOrder()).put(bytes)
            data.position(0)
            // On disk the shader's 32-bit floats, as mpv's hook has them.
            GLES30.glTexImage2D(GLES30.GL_TEXTURE_2D, 0, GLES30.GL_RGBA16F, 13, 288, 0, GLES30.GL_RGBA, GLES30.GL_FLOAT, data)
        }
        private var width = 0
        private var height = 0
        private var lumaTarget: Target? = null
        private var workTarget: Target? = null
        private var doubledTarget: Target? = null
        private var outputWidth = 0
        private var outputHeight = 0

        // Whether this GPU keeps up, from the shader's own time against the time between pictures: a GPU that doesn't falls back to plain
        // scaling for the rest of the title, so the upscaler never costs a dropped frame.
        private var fellBack = false
        private var lastPresentationUs = Long.MIN_VALUE
        private var intervalMs = 0f
        private var frames = 0
        private var overBudget = 0
        private var windowFrames = 0
        private var windowMs = 0f
        private var windowMaxMs = 0f
        private var lastLog = 0L

        override fun configure(inputWidth: Int, inputHeight: Int): Size {
            releaseTargets()
            width = inputWidth
            height = inputHeight
            val output = LambentUpscalePolicy.outputSize(inputWidth, inputHeight, screenWidth, screenHeight)
            outputWidth = output?.first ?: inputWidth
            outputHeight = output?.second ?: inputHeight
            if (output != null) {
                lumaTarget = Target(width, height, GLES30.GL_R16F, GLES30.GL_RED, GLES30.GL_HALF_FLOAT, GLES30.GL_NEAREST)
                workTarget = Target(width, height, GLES30.GL_RGBA16F, GLES30.GL_RGBA, GLES30.GL_HALF_FLOAT, GLES30.GL_NEAREST)
                doubledTarget = Target(width * 2, height * 2, GLES30.GL_R16F, GLES30.GL_RED, GLES30.GL_HALF_FLOAT, GLES30.GL_LINEAR)
            }
            Log.i(TAG, "${inputWidth}x$inputHeight to ${outputWidth}x$outputHeight, RAVU-lite ${if (output != null) "on" else "not needed"}")
            return Size(outputWidth, outputHeight)
        }

        override fun drawFrame(inputTexId: Int, presentationTimeUs: Long) {
            val bound = IntArray(1)
            GLES30.glGetIntegerv(GLES30.GL_FRAMEBUFFER_BINDING, bound, 0)
            val output = bound[0]
            GLES30.glBindVertexArray(vertexArray)
            readTiming(presentationTimeUs)
            val lumaPass = lumaTarget
            val work = workTarget
            val doubled = doubledTarget
            if (lumaPass == null || work == null || doubled == null || fellBack) {
                draw(output, outputWidth, outputHeight, plain, "src" to inputTexId)
            } else {
                if (!queryPending) GLES30.glBeginQuery(TIME_ELAPSED, query)
                val timing = !queryPending
                draw(lumaPass.framebuffer, width, height, luma, "src" to inputTexId)
                sizes(step1)
                draw(work.framebuffer, width, height, step1, "HOOKED" to lumaPass.texture, "ravu_lite_lut3" to lut)
                sizes(step2)
                draw(doubled.framebuffer, width * 2, height * 2, step2, "HOOKED" to lumaPass.texture, "ravu_lite_int" to work.texture)
                draw(output, outputWidth, outputHeight, merge, "src" to inputTexId, "luma" to doubled.texture)
                if (timing) {
                    GLES30.glEndQuery(TIME_ELAPSED)
                    queryPending = true
                }
            }
            GLES30.glBindVertexArray(0)
            GlUtil.checkGlError()
        }

        private fun sizes(program: Int) {
            GLES30.glUseProgram(program)
            GLES30.glUniform2f(GLES30.glGetUniformLocation(program, "HOOKED_size"), width.toFloat(), height.toFloat())
            GLES30.glUniform2f(GLES30.glGetUniformLocation(program, "HOOKED_pt"), 1f / width, 1f / height)
        }

        private fun draw(framebuffer: Int, w: Int, h: Int, program: Int, vararg textures: Pair<String, Int>) {
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

        private fun readTiming(presentationTimeUs: Long) {
            val delta = (presentationTimeUs - lastPresentationUs) / 1000f
            lastPresentationUs = presentationTimeUs
            if (delta > 0f && delta < 1000f) intervalMs = if (intervalMs == 0f) delta else intervalMs + (delta - intervalMs) * 0.05f
            if (!queryPending) return
            val available = IntArray(1)
            GLES30.glGetQueryObjectuiv(query, GLES30.GL_QUERY_RESULT_AVAILABLE, available, 0)
            if (available[0] == 0) return
            val nanoseconds = IntArray(1)
            GLES30.glGetQueryObjectuiv(query, GLES30.GL_QUERY_RESULT, nanoseconds, 0)
            queryPending = false
            val ms = nanoseconds[0] / 1e6f
            frames++
            windowFrames++
            windowMs += ms
            if (ms > windowMaxMs) windowMaxMs = ms
            // The clocks settle over the first pictures.
            if (frames > WARM_UP_FRAMES && intervalMs > 0f) {
                overBudget = if (ms > intervalMs * BUDGET) overBudget + 1 else maxOf(0, overBudget - 1)
                if (overBudget >= FALL_BACK_AFTER) {
                    fellBack = true
                    Log.w(TAG, "RAVU-lite off for this title: %.2f ms a picture, %.1f ms between them".format(ms, intervalMs))
                }
            }
            val now = android.os.SystemClock.elapsedRealtime()
            if (now - lastLog >= 2000) {
                Log.i(TAG, "frames %d gpu_ms mean %.2f max %.2f interval_ms %.1f over %d".format(windowFrames, windowMs / windowFrames, windowMaxMs, intervalMs, overBudget))
                lastLog = now
                windowFrames = 0
                windowMs = 0f
                windowMaxMs = 0f
            }
        }

        private fun releaseTargets() {
            lumaTarget?.release()
            workTarget?.release()
            doubledTarget?.release()
            lumaTarget = null
            workTarget = null
            doubledTarget = null
        }

        override fun release() {
            super.release()
            releaseTargets()
            GLES30.glDeleteTextures(1, intArrayOf(lut), 0)
            listOf(luma, step1, step2, merge, plain).forEach(GLES30::glDeleteProgram)
            GLES30.glDeleteVertexArrays(1, intArrayOf(vertexArray), 0)
            GLES30.glDeleteQueries(1, intArrayOf(query), 0)
        }
    }

    private companion object {
        const val TAG = "LambentUpscale"
        const val TIME_ELAPSED = 0x88BF
        const val BUDGET = 0.8f
        const val WARM_UP_FRAMES = 30
        const val FALL_BACK_AFTER = 48

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
