package org.moonfin.nativevideo

import android.content.Context
import android.graphics.SurfaceTexture
import android.hardware.display.DisplayManager
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES30
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Process
import android.os.SystemClock
import android.util.Log
import android.view.Display
import android.view.Surface
import android.view.SurfaceHolder
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Lambent Auto HDR on an Android TV (the Apple players' LambentHDRLift): an SDR title made HDR10 here by the bank of sixteen tables
 * ([LambentAutoHdrBank]). Where the device's step asks for it ([LambentAutoHdrPolicy.asked]) and the screensaver-time benchmark says
 * this device keeps up ([LambentAutoHdrBench]), ExoPlayer decodes into this renderer's SurfaceTexture instead of the SurfaceView, and the
 * renderer draws each picture through its table, scaled to the surface (bilinear), into the SurfaceView's surface as fp16 BT.2020 PQ with
 * HDR10 metadata, at the time ExoPlayer released it. Media3's own video effects can't: their HDR path needs EXT_YUV_target, which a
 * Shield doesn't have (2026-11-01, Lambent's companion/spikes/android-hdr-probe). The Shield then switches its HDMI output to HDR10 and
 * sends the metadata (1000 nits peak, 400 average). Dolby Vision is not possible from an app's own picture; titles that are already HDR
 * or Dolby Vision never come here.
 */
internal class LambentAutoHdrRenderer private constructor(
    private val context: Context,
    /** RAVU-lite's luma under the picture's chroma as it is scaled (RavuLite in LambentUpscale.kt); else bilinear. */
    private val useRavu: Boolean,
) : SurfaceTexture.OnFrameAvailableListener {
    private val thread = HandlerThread("LambentAutoHdr", Process.THREAD_PRIORITY_DISPLAY).apply { start() }
    private val gl = Handler(thread.looper)
    private var dpy: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var ctx: EGLContext = EGL14.EGL_NO_CONTEXT
    private var config: EGLConfig? = null
    private var idle: EGLSurface = EGL14.EGL_NO_SURFACE
    private var window: EGLSurface = EGL14.EGL_NO_SURFACE
    private var windowFor: Surface? = null
    private var oes = 0
    private var st: SurfaceTexture? = null
    private var bank: LambentAutoHdrBank? = null
    private var copyProg = 0
    private var finalProg = 0
    private var vertexArray = 0
    private var ravu: RavuLite? = null
    // The decoded picture copied once, at its own size, rows bottom-up: what the bank, RAVU-lite and the last pass read.
    private var srcTex = 0
    private var srcFbo = 0
    private var srcW = 0
    private var srcH = 0
    private var outW = 0
    private var outH = 0
    private val stm = FloatArray(16)
    private val quad: FloatBuffer = ByteBuffer.allocateDirect(32).order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
        put(floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f)).position(0)
    }
    private val compare = compareSplit()
    private val tableTimer = GpuTimer()
    private val liftTimer = GpuTimer()
    private var frames = 0
    private var drawn = 0
    private var arrived = 0
    private var unannounced = 0
    private var lastTimestamp = 0L
    private var lastPictureAt = 0L
    private var arrivedInWindow = 0
    private var windowStart = 0L
    private var holder: SurfaceHolder? = null
    @Volatile private var released = false

    /** The decoded picture's size, which the bank's thumbnail reads by (the decoder's own, from onVideoSizeChanged). */
    @Volatile var sourceWidth = 1920
    @Volatile var sourceHeight = 1080

    /** Where ExoPlayer decodes to (`setVideoSurface`). */
    lateinit var inputSurface: Surface
        private set

    private val holderCallback = object : SurfaceHolder.Callback {
        override fun surfaceCreated(h: SurfaceHolder) { Log.i(TAG, "surface created"); attach(h.surface) }
        override fun surfaceChanged(h: SurfaceHolder, format: Int, width: Int, height: Int) {
            Log.i(TAG, "surface changed: ${width}x$height format $format")
            attach(h.surface)
        }
        override fun surfaceDestroyed(h: SurfaceHolder) { Log.i(TAG, "surface destroyed"); detachAndWait() }
    }

    /** Draws into `holder`'s surface from now on (its format and fixed size set by the caller). */
    fun bind(holder: SurfaceHolder) {
        this.holder?.removeCallback(holderCallback)
        this.holder = holder
        holder.addCallback(holderCallback)
        holder.surface?.takeIf { it.isValid }?.let { attach(it) }
    }

    fun release() {
        if (released) return
        released = true
        gl.removeCallbacks(report)
        gl.removeCallbacks(poll)
        holder?.removeCallback(holderCallback)
        holder = null
        val done = CountDownLatch(1)
        gl.post {
            runCatching {
                st?.setOnFrameAvailableListener(null)
                st?.release()
                inputSurface.release()
                destroyWindow()
                bank?.release()
                ravu?.release()
                for (p in intArrayOf(copyProg, finalProg)) if (p != 0) GLES30.glDeleteProgram(p)
                if (vertexArray != 0) GLES30.glDeleteVertexArrays(1, intArrayOf(vertexArray), 0)
                if (srcTex != 0) GLES30.glDeleteTextures(1, intArrayOf(srcTex), 0)
                if (srcFbo != 0) GLES30.glDeleteFramebuffers(1, intArrayOf(srcFbo), 0)
                EGL14.eglMakeCurrent(dpy, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
                if (idle != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(dpy, idle)
                EGL14.eglDestroyContext(dpy, ctx)
            }
            done.countDown()
        }
        done.await(1, TimeUnit.SECONDS)
        thread.quitSafely()
    }

    private fun setUp(): Boolean {
        val egl = Egl.open(window = true) ?: return false
        dpy = egl.display
        ctx = egl.context
        config = egl.config
        idle = egl.idle
        if (!EGL14.eglMakeCurrent(dpy, idle, idle, ctx)) return false
        bank = LambentAutoHdrBank.create(context, external = false) ?: return false
        copyProg = LambentAutoHdrBank.program(LambentAutoHdrBank.VS, COPY_FS)
        finalProg = LambentAutoHdrBank.program(LambentUpscaleEffect.VERTEX, FINAL_FS)
        vertexArray = IntArray(1).also { GLES30.glGenVertexArrays(1, it, 0) }[0]
        if (useRavu) ravu = RavuLite(context)
        val t = IntArray(1)
        GLES30.glGenTextures(1, t, 0)
        oes = t[0]
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oes)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
        val texture = SurfaceTexture(oes)
        texture.setOnFrameAvailableListener(this, gl)
        st = texture
        inputSurface = Surface(texture)
        windowStart = SystemClock.elapsedRealtime()
        gl.postDelayed(report, 30_000)
        gl.postDelayed(poll, POLL_MS)
        return GLES30.glGetError() == GLES30.GL_NO_ERROR
    }

    private fun attach(surface: Surface) {
        gl.post {
            if (released || (windowFor === surface && window != EGL14.EGL_NO_SURFACE)) return@post
            destroyWindow()
            val attribs = intArrayOf(EGL_GL_COLORSPACE_KHR, EGL_GL_COLORSPACE_BT2020_PQ_EXT, EGL14.EGL_NONE)
            val made = runCatching { EGL14.eglCreateWindowSurface(dpy, config, surface, attribs, 0) }.getOrNull()
            if (made == null || made == EGL14.EGL_NO_SURFACE) {
                Log.w(TAG, "no PQ window surface: 0x${Integer.toHexString(EGL14.eglGetError())}")
                return@post
            }
            window = made
            windowFor = surface
            EGL14.eglMakeCurrent(dpy, window, window, ctx)
            // BT.2020 primaries, D65, 1000 nits: what Lambent's own HDR10 streams carry (the bank's peak).
            val primaries = floatArrayOf(0.708f, 0.292f, 0.170f, 0.797f, 0.131f, 0.046f, 0.3127f, 0.3290f)
            for (i in 0 until 8) EGL14.eglSurfaceAttrib(dpy, window, EGL_SMPTE2086_DISPLAY_PRIMARY_RX_EXT + i, Math.round(primaries[i] * SCALE))
            EGL14.eglSurfaceAttrib(dpy, window, EGL_SMPTE2086_MAX_LUMINANCE_EXT, 1000 * SCALE)
            EGL14.eglSurfaceAttrib(dpy, window, EGL_SMPTE2086_MIN_LUMINANCE_EXT, SCALE / 1000)
            EGL14.eglSurfaceAttrib(dpy, window, EGL_CTA861_3_MAX_CONTENT_LIGHT_LEVEL_EXT, 1000 * SCALE)
            EGL14.eglSurfaceAttrib(dpy, window, EGL_CTA861_3_MAX_FRAME_AVERAGE_LEVEL_EXT, 400 * SCALE)
            val v = IntArray(1)
            EGL14.eglQuerySurface(dpy, window, EGL14.EGL_WIDTH, v, 0); outW = v[0]
            EGL14.eglQuerySurface(dpy, window, EGL14.EGL_HEIGHT, v, 0); outH = v[0]
            Log.i(TAG, "drawing ${outW}x$outH BT.2020 PQ from ${sourceWidth}x$sourceHeight")
        }
    }

    private fun detachAndWait() {
        val done = CountDownLatch(1)
        gl.post { destroyWindow(); done.countDown() }
        done.await(500, TimeUnit.MILLISECONDS)
    }

    private fun destroyWindow() {
        if (window == EGL14.EGL_NO_SURFACE) return
        EGL14.eglMakeCurrent(dpy, idle, idle, ctx)
        EGL14.eglDestroySurface(dpy, window)
        window = EGL14.EGL_NO_SURFACE
        windowFor = null
    }

    override fun onFrameAvailable(texture: SurfaceTexture) {
        if (released) return
        arrived++
        arrivedInWindow++
        texture.updateTexImage()
        // The poll may have taken this picture already: nothing new to draw.
        if (texture.timestamp == lastTimestamp) return
        lastTimestamp = texture.timestamp
        lastPictureAt = SystemClock.uptimeMillis()
        draw(texture)
    }

    /**
     * A picture can sit in the SurfaceTexture's queue with no callback for it, and the decoder, out of buffers, then stops (seen on a
     * Shield 2026-11-17: 145 pictures released, ~135 callbacks, then none). So between callbacks the queue is also looked at: a picture
     * found there is drawn as if it had been announced.
     */
    private val poll: Runnable = object : Runnable {
        override fun run() {
            if (released) return
            val texture = st
            if (texture != null && SystemClock.uptimeMillis() - lastPictureAt >= POLL_MS) {
                texture.updateTexImage()
                if (texture.timestamp != lastTimestamp) {
                    lastTimestamp = texture.timestamp
                    lastPictureAt = SystemClock.uptimeMillis()
                    unannounced++
                    draw(texture)
                }
            }
            gl.postDelayed(this, POLL_MS)
        }
    }

    private fun draw(texture: SurfaceTexture) {
        if (window == EGL14.EGL_NO_SURFACE) return
        texture.getTransformMatrix(stm)
        val bank = bank ?: return
        // The surface's size follows the SurfaceView's fixed size, which can land after the window was made.
        val v = IntArray(1)
        EGL14.eglQuerySurface(dpy, window, EGL14.EGL_WIDTH, v, 0); outW = v[0]
        EGL14.eglQuerySurface(dpy, window, EGL14.EGL_HEIGHT, v, 0); outH = v[0]
        val sw = sourceWidth
        val sh = sourceHeight
        ensureSource(sw, sh)
        tableTimer.time {
            // The decoder's picture into the source texture (its transform applied once), then this picture's table from it.
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, srcFbo)
            GLES30.glViewport(0, 0, sw, sh)
            GLES30.glUseProgram(copyProg)
            GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
            GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oes)
            GLES30.glUniform1i(GLES30.glGetUniformLocation(copyProg, "tex"), 0)
            GLES30.glUniformMatrix4fv(GLES30.glGetUniformLocation(copyProg, "st"), 1, false, stm, 0)
            val pos = GLES30.glGetAttribLocation(copyProg, "pos")
            GLES30.glEnableVertexAttribArray(pos)
            GLES30.glVertexAttribPointer(pos, 2, GLES30.GL_FLOAT, false, 0, quad)
            GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4)
            bank.encode(srcTex, LambentAutoHdrBank.IDENTITY, sw, sh)
        }
        liftTimer.time {
            val luma = ravu?.let { it.configure(sw, sh); it.doubledLuma(srcTex) }
            finalPass(finalProg, vertexArray, 0, outW, outH, srcTex, luma, bank.lut, if (compare) outW / 2f else 0f)
        }
        // Shown when ExoPlayer meant it to be: the release time it gave the decoder's buffer.
        val ts = texture.timestamp
        val clock = System.nanoTime()
        if (PRESENT_AT_TIMESTAMP) EGLExt.eglPresentationTimeANDROID(dpy, window, ts)
        EGL14.eglSwapBuffers(dpy, window)
        val swapMs = (System.nanoTime() - clock) / 1e6
        drawn++
        if (swapMs > 100) Log.w(TAG, String.format("picture %d: swap took %.1f ms (shown %.1f ms from now)", drawn, swapMs, (ts - clock) / 1e6))
        frames++
    }

    private fun ensureSource(w: Int, h: Int) {
        if (w == srcW && h == srcH && srcTex != 0) return
        if (srcTex != 0) GLES30.glDeleteTextures(1, intArrayOf(srcTex), 0)
        if (srcFbo == 0) srcFbo = IntArray(1).also { GLES30.glGenFramebuffers(1, it, 0) }[0]
        srcTex = LambentUpscaleEffect.newTexture(GLES30.GL_LINEAR)
        GLES30.glTexStorage2D(GLES30.GL_TEXTURE_2D, 1, GLES30.GL_RGBA16F, w, h)
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, srcFbo)
        GLES30.glFramebufferTexture2D(GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0, GLES30.GL_TEXTURE_2D, srcTex, 0)
        srcW = w
        srcH = h
    }

    /** Every 30 s: pictures in and drawn a second, and the GPU's time for each step. */
    private val report: Runnable = object : Runnable {
        override fun run() {
            if (released) return
            val now = SystemClock.elapsedRealtime()
            val secs = (now - windowStart) / 1000f
            Log.i(
                TAG,
                String.format(
                    "%.2f pictures in, %.2f drawn a second (%d found without a callback), %dx%d -> %dx%d, window %b, table %s, lift %s",
                    arrivedInWindow / secs, frames / secs, unannounced, sourceWidth, sourceHeight, outW, outH, window != EGL14.EGL_NO_SURFACE,
                    tableTimer.take(), liftTimer.take(),
                ),
            )
            frames = 0
            arrivedInWindow = 0
            unannounced = 0
            windowStart = now
            gl.postDelayed(this, 30_000)
        }
    }

    companion object {
        const val TAG = "LambentAutoHdr"
        private const val EGL_GL_COLORSPACE_KHR = 0x309D
        private const val EGL_GL_COLORSPACE_BT2020_PQ_EXT = 0x3340
        private const val EGL_SMPTE2086_DISPLAY_PRIMARY_RX_EXT = 0x3341
        private const val EGL_SMPTE2086_MAX_LUMINANCE_EXT = 0x3349
        private const val EGL_SMPTE2086_MIN_LUMINANCE_EXT = 0x334A
        private const val EGL_CTA861_3_MAX_CONTENT_LIGHT_LEVEL_EXT = 0x3360
        private const val EGL_CTA861_3_MAX_FRAME_AVERAGE_LEVEL_EXT = 0x3361
        private const val SCALE = 50000
        private const val PRESENT_AT_TIMESTAMP = true
        private const val POLL_MS = 20L

        /** A renderer ready for ExoPlayer's pictures, or null where this device can't (no PQ surfaces, no fp16 window, no weights). */
        fun create(context: Context, sourceWidth: Int, sourceHeight: Int, useRavu: Boolean): LambentAutoHdrRenderer? {
            val r = LambentAutoHdrRenderer(context.applicationContext, useRavu)
            if (sourceWidth > 0 && sourceHeight > 0) { r.sourceWidth = sourceWidth; r.sourceHeight = sourceHeight }
            var ok = false
            val done = CountDownLatch(1)
            r.gl.post {
                ok = runCatching { r.setUp() }.onFailure { Log.w(TAG, "set up failed", it) }.getOrDefault(false)
                done.countDown()
            }
            if (!done.await(3, TimeUnit.SECONDS) || !ok) {
                r.release()
                return null
            }
            return r
        }

        private const val COPY_FS = "#version 300 es\n#extension GL_OES_EGL_image_external_essl3 : require\nprecision highp float;\n" +
            "uniform samplerExternalOES tex; in vec2 uv; out vec4 color;\n" +
            "void main() { color = vec4(clamp(texture(tex, uv).rgb, 0.0, 1.0), 1.0); }\n"

        /**
         * The last pass, to the surface's size: the source scaled (bilinear), RAVU-lite's doubled luma put under its chroma where
         * `useLuma` (LambentUpscaleEffect's MERGE), and that through the picture's table. `split` > 0 (a test's compare,
         * [compareSplit]): left of it the picture as an HDR television shows SDR (BT.2408: BT.1886 light, white at 203 nits, BT.709 in
         * BT.2020), right of it Auto HDR, with a thin line between.
         */
        const val FINAL_FS = "#version 300 es\nprecision highp float;\nprecision highp sampler2D;\nprecision highp sampler3D;\n" +
            "in vec2 v; out vec4 fragColor;\n" +
            "uniform sampler2D src; uniform sampler2D luma; uniform sampler3D lut; uniform float useLuma; uniform float split;\n" +
            LambentAutoHdrBank.LIFT_LOOKUP +
            "vec3 pqf(vec3 nits) { const float m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;\n" +
            "  vec3 l = pow(clamp(nits / 10000.0, 0.0, 1.0), vec3(m1)); return pow((c1 + c2 * l) / (1.0 + c3 * l), vec3(m2)); }\n" +
            "vec3 sdrInHdr(vec3 rgb) { const mat3 to2020 = mat3(vec3(0.6274, 0.0691, 0.0164), vec3(0.3293, 0.9195, 0.0880), vec3(0.0433, 0.0114, 0.8956));\n" +
            "  return pqf(to2020 * pow(clamp(rgb, 0.0, 1.0), vec3(2.4)) * 203.0); }\n" +
            "void main() { vec3 c = texture(src, v).rgb;\n" +
            "  if (useLuma > 0.5) c = clamp(c + (texture(luma, v).r - dot(c, vec3(0.2126, 0.7152, 0.0722))), 0.0, 1.0);\n" +
            "  if (split > 0.0 && abs(gl_FragCoord.x - split) < 2.0) { fragColor = vec4(pqf(vec3(100.0)), 1.0); return; }\n" +
            "  fragColor = vec4(split > 0.0 && gl_FragCoord.x < split ? sdrInHdr(c) : lifted(c), 1.0); }\n"

        /** [FINAL_FS] into `framebuffer` at `w` x `h` (the renderer's surface, or the bench's target). */
        fun finalPass(prog: Int, vertexArray: Int, framebuffer: Int, w: Int, h: Int, src: Int, luma: Int?, lut: Int, split: Float) {
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, framebuffer)
            GLES30.glViewport(0, 0, w, h)
            GLES30.glUseProgram(prog)
            GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, src)
            GLES30.glActiveTexture(GLES30.GL_TEXTURE1)
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, luma ?: src)
            GLES30.glActiveTexture(GLES30.GL_TEXTURE2)
            GLES30.glBindTexture(GLES30.GL_TEXTURE_3D, lut)
            GLES30.glUniform1i(GLES30.glGetUniformLocation(prog, "src"), 0)
            GLES30.glUniform1i(GLES30.glGetUniformLocation(prog, "luma"), 1)
            GLES30.glUniform1i(GLES30.glGetUniformLocation(prog, "lut"), 2)
            GLES30.glUniform1f(GLES30.glGetUniformLocation(prog, "useLuma"), if (luma != null) 1f else 0f)
            GLES30.glUniform1f(GLES30.glGetUniformLocation(prog, "split"), split)
            GLES30.glBindVertexArray(vertexArray)
            GLES30.glDrawArrays(GLES30.GL_TRIANGLES, 0, 3)
            GLES30.glBindVertexArray(0)
            GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        }

        /** A test's side-by-side (`adb shell setprop debug.lambent.autohdr.compare 1`): read when a title starts. */
        private fun compareSplit(): Boolean = runCatching {
            Class.forName("android.os.SystemProperties").getMethod("get", String::class.java).invoke(null, "debug.lambent.autohdr.compare") == "1"
        }.getOrDefault(false)
    }
}

/** An EGL display and GLES 3.1 context: with an fp16 window config for the renderer (`window`), else plain, for the offscreen bench. */
internal class Egl(val display: EGLDisplay, val context: EGLContext, val config: EGLConfig, val idle: EGLSurface) {
    companion object {
        private const val EGL_OPENGL_ES3_BIT = 0x40
        private const val EGL_COLOR_COMPONENT_TYPE_EXT = 0x3339
        private const val EGL_COLOR_COMPONENT_TYPE_FLOAT_EXT = 0x333B

        fun open(window: Boolean): Egl? {
            val dpy = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
            val v = IntArray(2)
            if (!EGL14.eglInitialize(dpy, v, 0, v, 1)) return null
            val ext = EGL14.eglQueryString(dpy, EGL14.EGL_EXTENSIONS) ?: ""
            if (window && (!ext.contains("EGL_EXT_gl_colorspace_bt2020_pq") || !ext.contains("EGL_EXT_pixel_format_float"))) {
                Log.i(LambentAutoHdrRenderer.TAG, "no BT.2020 PQ / float window surfaces here")
                return null
            }
            val surfaceless = ext.contains("EGL_KHR_surfaceless_context")
            val attribs = if (window) {
                intArrayOf(
                    EGL14.EGL_RED_SIZE, 16, EGL14.EGL_GREEN_SIZE, 16, EGL14.EGL_BLUE_SIZE, 16, EGL14.EGL_ALPHA_SIZE, 16,
                    EGL_COLOR_COMPONENT_TYPE_EXT, EGL_COLOR_COMPONENT_TYPE_FLOAT_EXT,
                    EGL14.EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL14.EGL_SURFACE_TYPE,
                    EGL14.EGL_WINDOW_BIT or (if (surfaceless) 0 else EGL14.EGL_PBUFFER_BIT), EGL14.EGL_NONE,
                )
            } else {
                intArrayOf(
                    EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
                    EGL14.EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT, EGL14.EGL_NONE,
                )
            }
            val configs = arrayOfNulls<EGLConfig>(1)
            val n = IntArray(1)
            if (!EGL14.eglChooseConfig(dpy, attribs, 0, configs, 0, 1, n, 0) || n[0] == 0) {
                Log.i(LambentAutoHdrRenderer.TAG, "no ${if (window) "fp16 window" else "offscreen"} EGL config")
                return null
            }
            val config = configs[0]!!
            val ctx = EGL14.eglCreateContext(dpy, config, EGL14.EGL_NO_CONTEXT, intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE), 0)
            if (ctx == null || ctx == EGL14.EGL_NO_CONTEXT) return null
            val idle = if (window && surfaceless) {
                EGL14.EGL_NO_SURFACE
            } else {
                EGL14.eglCreatePbufferSurface(dpy, config, intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0)
            }
            return Egl(dpy, ctx, config, idle)
        }
    }
}

/** GL_TIME_ELAPSED queries in a ring, read back without waiting. */
internal class GpuTimer {
    private val queries = IntArray(8)
    private var head = 0
    private var tail = 0
    private val ms = FloatArray(600)
    private var n = 0
    private var made = false

    fun time(block: () -> Unit) {
        if (!made) { GLES30.glGenQueries(queries.size, queries, 0); made = true }
        if (head - tail < queries.size) {
            GLES30.glBeginQuery(GL_TIME_ELAPSED_EXT, queries[head % queries.size])
            block()
            GLES30.glEndQuery(GL_TIME_ELAPSED_EXT)
            head++
        } else {
            block()
        }
        val res = IntArray(1)
        while (tail < head) {
            val q = queries[tail % queries.size]
            GLES30.glGetQueryObjectuiv(q, GLES30.GL_QUERY_RESULT_AVAILABLE, res, 0)
            if (res[0] == 0) break
            GLES30.glGetQueryObjectuiv(q, GLES30.GL_QUERY_RESULT, res, 0)
            if (n < ms.size) ms[n++] = (res[0].toLong() and 0xffffffffL) / 1e6f
            tail++
        }
    }

    /** Mean and p95 ms since the last call. */
    fun take(): String {
        val g = ms.copyOf(n).also { it.sort() }
        n = 0
        if (g.isEmpty()) return "-"
        return String.format("%.2f ms (p95 %.2f)", g.average(), g[minOf(g.size - 1, (g.size * 0.95).toInt())])
    }

    companion object {
        const val GL_TIME_ELAPSED_EXT = 0x88BF
    }
}

/**
 * How long Auto HDR takes on this device (the owner, 2026-11-17: TV sticks may be too slow for the tables, so a device finds out while
 * idle): the bank's table and the lift to 4K for a 1080p picture and a 4K one, timed offscreen on the GPU, once per device and app
 * version, while Moonfin's own screensaver is up (the app is in front, so the GPU is ours) or when Lambent's settings ask what this
 * device can do. Playback never waits for it: until it has run, this device makes no Auto HDR.
 */
internal object LambentAutoHdrBench {
    private const val PREFS = "lambent_auto_hdr"
    /** ms a picture (90th percentile): the table, the lift to 4K bilinear, and the lift to 4K with RAVU-lite's passes (1080p only). */
    data class Result(val table1080: Float, val lift1080: Float, val table2160: Float, val lift2160: Float, val ravuLift1080: Float) {
        private fun big(width: Int, height: Int) = width.toLong() * height > 1920L * 1088
        fun ms(width: Int, height: Int): Float = if (big(width, height)) table2160 + lift2160 else table1080 + lift1080
        /** With RAVU-lite; infinity for a picture bigger than 1080p (RAVU-lite isn't asked to double one). */
        fun msWithRavu(width: Int, height: Int): Float = if (big(width, height)) Float.POSITIVE_INFINITY else table1080 + ravuLift1080
    }

    @Volatile private var running = false

    private fun key(context: Context): String {
        val version = runCatching {
            val info = context.packageManager.getPackageInfo(context.packageName, 0)
            if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else @Suppress("DEPRECATION") info.versionCode.toLong()
        }.getOrDefault(0L)
        // `b2`: the bench that also times RAVU-lite (2026-11-17); an older result runs again.
        return "${Build.FINGERPRINT}|$version|b2"
    }

    /** This device's timings for this app version, or null before the bench has run. */
    fun cached(context: Context): Result? {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (prefs.getString("key", null) != key(context)) return null
        return Result(
            prefs.getFloat("table1080", Float.NaN), prefs.getFloat("lift1080", Float.NaN),
            prefs.getFloat("table2160", Float.NaN), prefs.getFloat("lift2160", Float.NaN),
            prefs.getFloat("ravuLift1080", Float.NaN),
        ).takeIf { !it.table1080.isNaN() && !it.ravuLift1080.isNaN() }
    }

    /** Runs the bench on its own thread when this version hasn't yet; `done` gets the timings (or null) on that thread. */
    fun runIfNeeded(context: Context, done: (Result?) -> Unit = {}) {
        val app = context.applicationContext
        cached(app)?.let { done(it); return }
        if (running || Build.VERSION.SDK_INT < 29 || !LambentAutoHdrBank.available(app)) { done(null); return }
        running = true
        Thread({
            val result = runCatching { measure(app) }.onFailure { Log.w(LambentAutoHdrRenderer.TAG, "bench failed", it) }.getOrNull()
            val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString("key", key(app))
            if (result != null) {
                prefs.putFloat("table1080", result.table1080).putFloat("lift1080", result.lift1080)
                    .putFloat("table2160", result.table2160).putFloat("lift2160", result.lift2160)
                    .putFloat("ravuLift1080", result.ravuLift1080)
            } else {
                // Couldn't run here: remembered as never fitting, until the next version tries again.
                prefs.putFloat("table1080", 1e6f).putFloat("lift1080", 0f).putFloat("table2160", 1e6f).putFloat("lift2160", 0f)
                    .putFloat("ravuLift1080", 0f)
            }
            prefs.apply()
            running = false
            Log.i(LambentAutoHdrRenderer.TAG, "bench: $result")
            done(result)
        }, "LambentAutoHdrBench").start()
    }

    private fun measure(context: Context): Result? {
        val egl = Egl.open(window = false) ?: return null
        try {
            EGL14.eglMakeCurrent(egl.display, egl.idle, egl.idle, egl.context)
            val bank = LambentAutoHdrBank.create(context, external = false) ?: return null
            val final = LambentAutoHdrBank.program(LambentUpscaleEffect.VERTEX, LambentAutoHdrRenderer.FINAL_FS)
            val vertexArray = IntArray(1).also { GLES30.glGenVertexArrays(1, it, 0) }[0]
            val ravu = RavuLite(context)
            val t = IntArray(2)
            GLES30.glGenTextures(2, t, 0)
            val out = t[1]
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, out)
            GLES30.glTexStorage2D(GLES30.GL_TEXTURE_2D, 1, GLES30.GL_RGBA16F, 3840, 2160)
            val fbo = IntArray(1)
            GLES30.glGenFramebuffers(1, fbo, 0)
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, fbo[0])
            GLES30.glFramebufferTexture2D(GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0, GLES30.GL_TEXTURE_2D, out, 0)
            // table, bilinear lift, RAVU-lite lift: 90th percentile ms of 45 pictures after 15, for a 1080p and a 4K picture.
            val times = mutableListOf<FloatArray>()
            for ((w, h) in listOf(1920 to 1080, 3840 to 2160)) {
                val picture = t[0]
                GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, picture)
                GLES30.glTexImage2D(GLES30.GL_TEXTURE_2D, 0, GLES30.GL_RGBA8, w, h, 0, GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, pattern(w, h))
                GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
                GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
                val withRavu = w <= 1920
                if (withRavu) ravu.configure(w, h)
                val steps = if (withRavu) 3 else 2
                val q = IntArray(steps * 45)
                GLES30.glGenQueries(q.size, q, 0)
                for (i in 0 until 60) {
                    val timed = i >= 15
                    val k = (i - 15) * steps
                    fun step(n: Int, block: () -> Unit) {
                        if (timed) GLES30.glBeginQuery(GpuTimer.GL_TIME_ELAPSED_EXT, q[k + n])
                        block()
                        if (timed) GLES30.glEndQuery(GpuTimer.GL_TIME_ELAPSED_EXT)
                    }
                    step(0) { bank.encode(picture, LambentAutoHdrBank.IDENTITY, w, h) }
                    step(1) { LambentAutoHdrRenderer.finalPass(final, vertexArray, fbo[0], 3840, 2160, picture, null, bank.lut, 0f) }
                    if (withRavu) step(2) {
                        val luma = ravu.doubledLuma(picture)
                        LambentAutoHdrRenderer.finalPass(final, vertexArray, fbo[0], 3840, 2160, picture, luma, bank.lut, 0f)
                    }
                    GLES30.glFlush()
                }
                GLES30.glFinish()
                val res = IntArray(1)
                val p90 = FloatArray(3)
                for (n in 0 until steps) {
                    val ms = FloatArray(45) { i ->
                        GLES30.glGetQueryObjectuiv(q[i * steps + n], GLES30.GL_QUERY_RESULT, res, 0)
                        (res[0].toLong() and 0xffffffffL) / 1e6f
                    }
                    ms.sort()
                    p90[n] = ms[40]
                }
                GLES30.glDeleteQueries(q.size, q, 0)
                times.add(p90)
            }
            bank.release()
            ravu.release()
            GLES30.glDeleteProgram(final)
            GLES30.glDeleteVertexArrays(1, intArrayOf(vertexArray), 0)
            GLES30.glDeleteTextures(2, t, 0)
            GLES30.glDeleteFramebuffers(1, fbo, 0)
            return Result(times[0][0], times[0][1], times[1][0], times[1][1], times[0][2])
        } finally {
            EGL14.eglMakeCurrent(egl.display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            if (egl.idle != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(egl.display, egl.idle)
            EGL14.eglDestroyContext(egl.display, egl.context)
        }
    }

    /** Colour ramps with detail: the bench's picture (the work doesn't depend on what it shows). */
    private fun pattern(w: Int, h: Int): ByteBuffer {
        val b = ByteBuffer.allocateDirect(w * h * 4)
        for (y in 0 until h) for (x in 0 until w) {
            b.put((x * 255 / w).toByte()); b.put((y * 255 / h).toByte()); b.put(((x xor y) and 0xff).toByte()); b.put(-1)
        }
        b.position(0)
        return b
    }
}

/** When an SDR title is made HDR10 here (LambentClientUpscale.swift's `planLift` and the iPad's rules, on an Android TV). */
internal object LambentAutoHdrPolicy {
    /** Lambent's enhanced stream, or a direct play of the file (`/Videos/<id>/stream[.ext]`), whose query carries the device's steps. */
    private val directPath = Regex("/Videos/[^/]+/stream(\\.\\w+)?$")

    /** The device's step asks for Auto HDR: `chdr=1` from Lambent Server (paid), or the player's own licence (`lambentLift`). */
    fun asked(url: String, lambentLift: Boolean): Boolean {
        if (lambentLift) return true
        val uri = runCatching { android.net.Uri.parse(url) }.getOrNull() ?: return false
        val path = uri.path ?: return false
        if (!path.contains("/v1/enhanced/") && !directPath.containsMatchIn(path)) return false
        return runCatching { uri.getQueryParameters("chdr").lastOrNull()?.trim() == "1" }.getOrDefault(false)
    }

    /** The television takes HDR10 (its EDID, whatever mode the box is in now). */
    fun displayTakesHdr10(context: Context): Boolean {
        val display = context.getSystemService(DisplayManager::class.java)?.getDisplay(Display.DEFAULT_DISPLAY) ?: return false
        return runCatching { display.hdrCapabilities?.supportedHdrTypes?.contains(Display.HdrCapabilities.HDR_TYPE_HDR10) == true }
            .getOrDefault(false)
    }

    /**
     * The bench says a `width` x `height` picture at `fps` keeps up: the table and the lift within 60 % of a frame, the rest left for the
     * decoder, the compositor and the app. A Shield Pro (2019): a 1080p title 8 ms, a 4K one 13 ms, so up to 60 fps and 30 fps.
     */
    fun fits(context: Context, fps: Float?, width: Int, height: Int): Boolean = mode(context, fps, width, height, wantsRavu = false) != Mode.OFF

    enum class Mode { RAVU, BILINEAR, OFF }

    /**
     * How Auto HDR runs for a `width` x `height` picture at `fps`: with RAVU-lite where it is asked for (`wantsRavu`: the picture is
     * scaled enough for it) and both fit, else bilinear where the tables fit (Auto HDR may cost a step of the same kind of upscaling, the
     * owner's order, 2026-11-08), else not at all (the title keeps RAVU-lite alone). Each within 60 % of a frame.
     */
    fun mode(context: Context, fps: Float?, width: Int, height: Int, wantsRavu: Boolean): Mode {
        val r = LambentAutoHdrBench.cached(context) ?: return Mode.OFF
        val budget = 0.6f * 1000f / (fps?.takeIf { it > 0f } ?: 30f)
        return when {
            wantsRavu && r.msWithRavu(width, height) <= budget -> Mode.RAVU
            r.ms(width, height) <= budget -> Mode.BILINEAR
            else -> Mode.OFF
        }
    }

    /** What the purchase screen may promise: Auto HDR for a 1080p film. */
    fun capable(context: Context): Boolean =
        Build.VERSION.SDK_INT >= 29 && LambentAutoHdrBank.available(context) && displayTakesHdr10(context) && fits(context, 24f, 1920, 1080)
}
