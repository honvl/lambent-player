package org.moonfin.nativevideo

import android.graphics.PixelFormat
import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES30
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

/**
 * Lambent's Auto HDR on the TV device: an SDR title direct-plays from the
 * server and is turned into HDR10 here, so the PC does no transcode.
 *
 * ExoPlayer decodes into [inputSurface] (a SurfaceTexture). Each picture is
 * drawn by one GLES fragment shader - Deepen blacks' bend, then Lambent's
 * TrueHDR-fitted curve on luminance, BT.709 to BT.2020, PQ - into the
 * SurfaceView's surface as an EGL window surface tagged BT.2020 PQ with
 * HDR10 metadata. SurfaceFlinger then puts the display in BT2100_PQ and the
 * hardware composer sends HDR10 over HDMI (measured on a Shield Pro, Android
 * 11: docs/CLIENT_HDR.md in Lambent). The Shield only has fp16 window configs,
 * so fp16 is tried first, then 10-10-10-2.
 *
 * A picture smaller than the display is upscaled here, not by the hardware
 * composer (whose stretch is soft and hides the picture from the TV's own
 * scaler): the surface is the display's size, a pass at the picture's size
 * bends the blacks (and sharpens, for Catmull-Rom), RAVU-lite (an mpv
 * shader loaded from the app's assets, LambentHookShader) doubles Y', and a
 * last pass at the display's size scales, lifts and writes PQ. Without the
 * shader file, Catmull-Rom with an RCAS-style sharpen.
 *
 * All GL work runs on its own thread. Logs `LambentHdr` every 2 s. For
 * measuring, a file `lambent_scaler` in the app's external files dir picks
 * the scaler (native, bilinear, catrom, ravu) and `lambent_dump` writes the
 * next picture's middle through every scaler as PNGs there.
 */
class LambentHdrStage(
    private val view: SurfaceView,
    private val deepenBlacks: Boolean,
) : SurfaceHolder.Callback, SurfaceTexture.OnFrameAvailableListener {
    private val thread = HandlerThread("lambent-hdr").apply { start() }
    private val gl = Handler(thread.looper)

    private var dpy: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var ctx: EGLContext = EGL14.EGL_NO_CONTEXT
    private var config: EGLConfig? = null
    private var pbuffer: EGLSurface = EGL14.EGL_NO_SURFACE
    private var window: EGLSurface = EGL14.EGL_NO_SURFACE
    private var fp16 = true
    private var program = 0
    private var measureProgram = 0
    private var prepProgram = 0
    private var prepSharpProgram = 0
    private val finalPrograms = HashMap<Scaler, Int>()
    private var ravu: LambentHookShader? = null
    private var pictureTex = 0
    private var pictureFbo = 0
    private var pictureW = 0
    private var pictureH = 0
    private var srcW = 0
    private var srcH = 0
    @Volatile private var scaler = Scaler.RAVU
    private var dumpTex = 0
    private var dumpFbo = 0
    private var oes = 0
    private var fbo = 0
    private var surfaceTexture: SurfaceTexture? = null
    private val stMatrix = FloatArray(16)
    private val quad: FloatBuffer = ByteBuffer.allocateDirect(32).order(ByteOrder.nativeOrder()).asFloatBuffer()
        .apply { put(floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f)).position(0) }
    private val measureBuffer: ByteBuffer = ByteBuffer.allocateDirect(MEASURE_W * MEASURE_H * 4)
    private var outW = 0
    private var outH = 0
    private var frameRate = 0f

    // Deepen blacks (Lambent's DeepenBlacks.swift): the 1st percentile of the middle 60%'s luma, followed over 8 s.
    private var floor = -1f
    private var lift = 0f
    private var floorTimeNs = 0L

    private var frames = 0
    private var available = 0
    private var frameIndex = 0
    private var gpuMs = FloatArray(512)
    private var gpuCount = 0
    private val queries = IntArray(8)
    private var queryHead = 0
    private var queryTail = 0
    private var windowStart = SystemClock.elapsedRealtime()

    @Volatile var isReady = false
        private set

    /** The surface ExoPlayer decodes into. Valid once [start] returns true. */
    var inputSurface: Surface? = null
        private set

    /** Sets up EGL and the input surface; false when the device cannot draw a BT.2020 PQ surface. */
    fun start(): Boolean {
        val done = java.util.concurrent.CountDownLatch(1)
        var ok = false
        gl.post {
            ok = runCatching { setUp() }.onFailure { Log.e(TAG, "set up failed", it) }.getOrDefault(false)
            done.countDown()
        }
        done.await()
        if (!ok) {
            release()
            return false
        }
        view.holder.addCallback(this)
        view.addOnLayoutChangeListener(layoutListener)
        view.holder.setFormat(if (fp16) PixelFormat.RGBA_F16 else PixelFormat.RGBA_1010102)
        if (view.holder.surface?.isValid == true) {
            val frame = view.holder.surfaceFrame
            surfaceChanged(view.holder, 0, frame.width(), frame.height())
        }
        isReady = true
        return true
    }

    /** The picture's size and rate: the surface is drawn at the picture's own size and the HWC scales it to the screen. */
    fun setVideoFormat(width: Int, height: Int, rate: Float) {
        if (width <= 0 || height <= 0) return
        frameRate = rate
        srcW = width
        srcH = height
        view.post { applySurfaceSize() }
        gl.post { surfaceTexture?.setDefaultBufferSize(width, height) }
    }

    private val layoutListener = android.view.View.OnLayoutChangeListener { _, l, t, r, b, ol, ot, or, ob ->
        if (r - l != or - ol || b - t != ob - ot) applySurfaceSize()
    }

    /** The surface is the view's size in display pixels when the stage scales, the picture's own size when the HWC does. */
    private fun applySurfaceSize() {
        if (srcW <= 0) return
        val display = view.display
        val physical = display?.mode?.physicalWidth ?: 0
        val logical = view.resources.displayMetrics.widthPixels
        val k = if (physical > 0 && logical > 0) physical.toFloat() / logical else 1f
        val w = Math.round(view.width * k)
        val h = Math.round(view.height * k)
        val scale = scaler != Scaler.NATIVE && w > srcW && h > srcH
        if (scale) view.holder.setFixedSize(w and 1.inv(), h and 1.inv()) else view.holder.setFixedSize(srcW, srcH)
    }

    fun release() {
        isReady = false
        view.holder.removeCallback(this)
        view.removeOnLayoutChangeListener(layoutListener)
        gl.post {
            ravu?.release()
            ravu = null
            surfaceTexture?.release()
            surfaceTexture = null
            inputSurface?.release()
            inputSurface = null
            if (dpy != EGL14.EGL_NO_DISPLAY) {
                EGL14.eglMakeCurrent(dpy, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
                if (window != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(dpy, window)
                if (pbuffer != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(dpy, pbuffer)
                if (ctx != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(dpy, ctx)
                EGL14.eglReleaseThread()
            }
            window = EGL14.EGL_NO_SURFACE
            pbuffer = EGL14.EGL_NO_SURFACE
            ctx = EGL14.EGL_NO_CONTEXT
            dpy = EGL14.EGL_NO_DISPLAY
            thread.quitSafely()
        }
    }

    override fun surfaceCreated(holder: SurfaceHolder) {}

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        val surface = holder.surface ?: return
        gl.post { makeWindow(surface, width, height) }
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        val done = java.util.concurrent.CountDownLatch(1)
        gl.post {
            dropWindow()
            done.countDown()
        }
        done.await()
    }

    private fun setUp(): Boolean {
        dpy = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        val version = IntArray(2)
        if (!EGL14.eglInitialize(dpy, version, 0, version, 1)) return false
        val extensions = EGL14.eglQueryString(dpy, EGL14.EGL_EXTENSIONS) ?: ""
        if (!extensions.contains("EGL_EXT_gl_colorspace_bt2020_pq")) {
            Log.i(TAG, "no EGL_EXT_gl_colorspace_bt2020_pq: HDR stays off")
            return false
        }
        config = chooseConfig(16) ?: chooseConfig(10)?.also { fp16 = false } ?: return false
        ctx = EGL14.eglCreateContext(dpy, config, EGL14.EGL_NO_CONTEXT, intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE), 0)
        if (ctx == EGL14.EGL_NO_CONTEXT) return false
        pbuffer = EGL14.eglCreatePbufferSurface(dpy, config, intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0)
        EGL14.eglMakeCurrent(dpy, pbuffer, pbuffer, ctx)
        program = program(VERTEX, LIFT)
        measureProgram = program(VERTEX, MEASURE)
        prepProgram = program(VERTEX, PREP)
        prepSharpProgram = program(VERTEX, defined(PREP, "SHARPEN"))
        for (sc in listOf(Scaler.BILINEAR, Scaler.CATROM, Scaler.RAVU)) finalPrograms[sc] = program(VERTEX_PLAIN, defined(FINAL, sc.name))
        if (program == 0 || measureProgram == 0 || prepProgram == 0 || prepSharpProgram == 0 || finalPrograms.values.any { it == 0 }) return false
        for (p in finalPrograms.values) {
            GLES30.glUseProgram(p)
            GLES30.glUniform1fv(GLES30.glGetUniformLocation(p, "curve"), 65, LambentToneCurve.table(peak = 1000f), 0)
            GLES30.glUniform1f(GLES30.glGetUniformLocation(p, "saturation"), 1f)
        }
        ravu = runCatching {
            view.context.assets.open(RAVU_ASSET).bufferedReader().use { it.readText() }
        }.getOrNull()?.let { LambentHookShader.load("ravu-lite-ar-r3", it) }
        scaler = if (ravu != null) Scaler.RAVU else Scaler.CATROM
        GLES30.glUseProgram(program)
        GLES30.glUniform1fv(GLES30.glGetUniformLocation(program, "curve"), 65, LambentToneCurve.table(peak = 1000f), 0)
        GLES30.glUniform1f(GLES30.glGetUniformLocation(program, "saturation"), 1f)
        val t = IntArray(1)
        GLES30.glGenTextures(1, t, 0)
        oes = t[0]
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oes)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
        GLES30.glGenTextures(1, t, 0)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, t[0])
        GLES30.glTexStorage2D(GLES30.GL_TEXTURE_2D, 1, GLES30.GL_RGBA8, MEASURE_W, MEASURE_H)
        val fb = IntArray(1)
        GLES30.glGenFramebuffers(1, fb, 0)
        fbo = fb[0]
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, fbo)
        GLES30.glFramebufferTexture2D(GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0, GLES30.GL_TEXTURE_2D, t[0], 0)
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
        GLES30.glGenQueries(queries.size, queries, 0)
        val st = SurfaceTexture(oes)
        st.setOnFrameAvailableListener(this, gl)
        surfaceTexture = st
        inputSurface = Surface(st)
        Log.i(TAG, "ready: ${if (fp16) "fp16" else "10-bit"} BT.2020 PQ, deepen blacks ${if (deepenBlacks) "on" else "off"}, scaler $scaler")
        return true
    }

    private fun chooseConfig(bits: Int): EGLConfig? {
        val attribs = intArrayOf(
            EGL14.EGL_RED_SIZE, bits, EGL14.EGL_GREEN_SIZE, bits, EGL14.EGL_BLUE_SIZE, bits,
            EGL14.EGL_ALPHA_SIZE, if (bits == 16) 16 else 2,
            EGL_COLOR_COMPONENT_TYPE_EXT, if (bits == 16) EGL_COLOR_COMPONENT_TYPE_FLOAT_EXT else EGL_COLOR_COMPONENT_TYPE_FIXED_EXT,
            EGL14.EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT or EGL14.EGL_PBUFFER_BIT,
            EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val n = IntArray(1)
        EGL14.eglChooseConfig(dpy, attribs, 0, configs, 0, 1, n, 0)
        return if (n[0] > 0) configs[0] else null
    }

    private fun makeWindow(surface: Surface, width: Int, height: Int) {
        if (ctx == EGL14.EGL_NO_CONTEXT || !surface.isValid) return
        dropWindow()
        window = EGL14.eglCreateWindowSurface(
            dpy, config, surface,
            intArrayOf(EGL_GL_COLORSPACE_KHR, EGL_GL_COLORSPACE_BT2020_PQ_EXT, EGL14.EGL_NONE), 0,
        )
        if (window == EGL14.EGL_NO_SURFACE) {
            Log.e(TAG, "window surface failed: 0x${Integer.toHexString(EGL14.eglGetError())}")
            return
        }
        outW = width
        outH = height
        // HDR10 metadata as the PC's streams carry it: BT.2020 primaries, D65, 1000 nits peak, MaxCLL 1000, MaxFALL 400.
        val primaries = floatArrayOf(0.708f, 0.292f, 0.170f, 0.797f, 0.131f, 0.046f, 0.3127f, 0.3290f)
        for (i in primaries.indices) {
            EGL14.eglSurfaceAttrib(dpy, window, EGL_SMPTE2086_DISPLAY_PRIMARY_RX_EXT + i, Math.round(primaries[i] * METADATA_SCALE))
        }
        EGL14.eglSurfaceAttrib(dpy, window, EGL_SMPTE2086_MAX_LUMINANCE_EXT, 1000 * METADATA_SCALE)
        EGL14.eglSurfaceAttrib(dpy, window, EGL_SMPTE2086_MIN_LUMINANCE_EXT, METADATA_SCALE / 200)
        EGL14.eglSurfaceAttrib(dpy, window, EGL_CTA861_3_MAX_CONTENT_LIGHT_LEVEL_EXT, 1000 * METADATA_SCALE)
        EGL14.eglSurfaceAttrib(dpy, window, EGL_CTA861_3_MAX_FRAME_AVERAGE_LEVEL_EXT, 400 * METADATA_SCALE)
        if (frameRate > 0f && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            runCatching { surface.setFrameRate(frameRate, Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE) }
        }
        EGL14.eglMakeCurrent(dpy, window, window, ctx)
        Log.i(TAG, "drawing into ${width}x$height")
    }

    private fun dropWindow() {
        if (window == EGL14.EGL_NO_SURFACE) return
        EGL14.eglMakeCurrent(dpy, pbuffer, pbuffer, ctx)
        EGL14.eglDestroySurface(dpy, window)
        window = EGL14.EGL_NO_SURFACE
    }

    override fun onFrameAvailable(texture: SurfaceTexture) {
        val st = surfaceTexture ?: return
        available++
        st.updateTexImage()
        if (window == EGL14.EGL_NO_SURFACE) return
        st.getTransformMatrix(stMatrix)
        if (deepenBlacks && frameIndex % 4 == 0) measure(st.timestamp)
        frameIndex++
        val timed = queryHead - queryTail < queries.size
        if (timed) GLES30.glBeginQuery(GL_TIME_ELAPSED_EXT, queries[queryHead % queries.size])
        if (dumpRequested) dump()
        render(currentScaler(), 0)
        if (timed) {
            GLES30.glEndQuery(GL_TIME_ELAPSED_EXT)
            queryHead++
        }
        collectQueries()
        EGL14.eglSwapBuffers(dpy, window)
        frames++
        report()
    }

    /** The scaler this picture gets: none when the surface is the picture's own size (or the picture is as big as the screen). */
    private fun currentScaler(): Scaler =
        if (scaler == Scaler.NATIVE || outW <= srcW || outH <= srcH) Scaler.NATIVE
        // RAVU-lite took 16-21 ms a 1080p -> 4K picture on a Shield Pro: inside a 24 or 30 fps frame, not a 50 or 60 fps one, where
        // Catmull-Rom (10 ms) runs instead (docs/CLIENT_HDR.md in Lambent).
        else if (scaler == Scaler.RAVU && (ravu == null || outW < srcW * 1.414f || frameRate > RAVU_MAX_FPS)) Scaler.CATROM
        else scaler

    /** One picture into framebuffer [fb] at outW x outH: the lift alone, or the picture pass, the prescaler and the final pass. */
    private fun render(sc: Scaler, fb: Int) {
        if (sc == Scaler.NATIVE) {
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, fb)
            GLES30.glViewport(0, 0, outW, outH)
            draw(program, 0f, 0f, 1f, 1f)
            return
        }
        ensurePicture(srcW, srcH)
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, pictureFbo)
        GLES30.glViewport(0, 0, srcW, srcH)
        val prep = if (sc == Scaler.CATROM) prepSharpProgram else prepProgram
        GLES30.glUseProgram(prep)
        GLES30.glUniform2f(GLES30.glGetUniformLocation(prep, "srcPt"), 1f / srcW, 1f / srcH)
        draw(prep, 0f, 0f, 1f, 1f)
        var hi = 0
        if (sc == Scaler.RAVU) hi = ravu!!.run(pictureTex, srcW, srcH, quad).first
        val fin = finalPrograms.getValue(sc)
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, fb)
        GLES30.glViewport(0, 0, outW, outH)
        GLES30.glUseProgram(fin)
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, pictureTex)
        GLES30.glUniform1i(GLES30.glGetUniformLocation(fin, "picture"), 0)
        GLES30.glActiveTexture(GLES30.GL_TEXTURE1)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, hi)
        GLES30.glUniform1i(GLES30.glGetUniformLocation(fin, "luma2x"), 1)
        GLES30.glUniform2f(GLES30.glGetUniformLocation(fin, "srcSize"), srcW.toFloat(), srcH.toFloat())
        val pos = GLES30.glGetAttribLocation(fin, "pos")
        GLES30.glEnableVertexAttribArray(pos)
        GLES30.glVertexAttribPointer(pos, 2, GLES30.GL_FLOAT, false, 0, quad)
        GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4)
    }

    private fun ensurePicture(w: Int, h: Int) {
        if (pictureTex != 0 && pictureW == w && pictureH == h) return
        if (pictureTex != 0) {
            GLES30.glDeleteFramebuffers(1, intArrayOf(pictureFbo), 0)
            GLES30.glDeleteTextures(1, intArrayOf(pictureTex), 0)
        }
        val t = IntArray(1)
        GLES30.glGenTextures(1, t, 0)
        pictureTex = t[0]
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, pictureTex)
        GLES30.glTexStorage2D(GLES30.GL_TEXTURE_2D, 1, GLES30.GL_RGBA16F, w, h)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glGenFramebuffers(1, t, 0)
        pictureFbo = t[0]
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, pictureFbo)
        GLES30.glFramebufferTexture2D(GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0, GLES30.GL_TEXTURE_2D, pictureTex, 0)
        pictureW = w
        pictureH = h
    }

    @Volatile private var dumpRequested = false

    /** The next picture's middle (a quarter of the screen) through every scaler, as PNGs of the PQ code values. */
    private fun dump() {
        dumpRequested = false
        val dir = view.context.getExternalFilesDir(null) ?: return
        if (dumpTex == 0) {
            val t = IntArray(1)
            GLES30.glGenTextures(1, t, 0)
            dumpTex = t[0]
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, dumpTex)
            GLES30.glTexStorage2D(GLES30.GL_TEXTURE_2D, 1, GLES30.GL_RGBA16F, 3840, 2160)
            GLES30.glGenFramebuffers(1, t, 0)
            dumpFbo = t[0]
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, dumpFbo)
            GLES30.glFramebufferTexture2D(GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0, GLES30.GL_TEXTURE_2D, dumpTex, 0)
        }
        val keepW = outW
        val keepH = outH
        for (sc in Scaler.values()) {
            if (sc == Scaler.RAVU && ravu == null) continue
            // The current path: the picture lifted at its own size, then stretched to the screen (here bilinear, as a stand-in for the HWC).
            outW = if (sc == Scaler.NATIVE) srcW else minOf(keepW, 3840)
            outH = if (sc == Scaler.NATIVE) srcH else minOf(keepH, 2160)
            render(sc, dumpFbo)
            val cw = outW / 4
            val ch = outH / 4
            val buf = ByteBuffer.allocateDirect(cw * ch * 16).order(ByteOrder.nativeOrder())
            GLES30.glReadPixels((outW - cw) / 2, (outH - ch) / 2, cw, ch, GLES30.GL_RGBA, GLES30.GL_FLOAT, buf)
            val f = buf.asFloatBuffer()
            val px = IntArray(cw * ch)
            for (y in 0 until ch) for (x in 0 until cw) {
                val i = ((ch - 1 - y) * cw + x) * 4
                fun c(v: Float) = (v.coerceIn(0f, 1f) * 255f + 0.5f).toInt()
                px[y * cw + x] = (0xff shl 24) or (c(f.get(i)) shl 16) or (c(f.get(i + 1)) shl 8) or c(f.get(i + 2))
            }
            val bmp = android.graphics.Bitmap.createBitmap(px, cw, ch, android.graphics.Bitmap.Config.ARGB_8888)
            java.io.File(dir, "dump_${sc.name.lowercase()}.png").outputStream().use { bmp.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
            Log.i(TAG, "dumped ${sc.name.lowercase()}: ${cw}x$ch of ${outW}x$outH")
        }
        outW = keepW
        outH = keepH
    }

    private fun draw(p: Int, x: Float, y: Float, w: Float, h: Float) {
        GLES30.glUseProgram(p)
        GLES30.glUniformMatrix4fv(GLES30.glGetUniformLocation(p, "st"), 1, false, stMatrix, 0)
        GLES30.glUniform4f(GLES30.glGetUniformLocation(p, "crop"), x, y, w, h)
        GLES30.glUniform2f(GLES30.glGetUniformLocation(p, "deepen"), if (deepenBlacks) lift else 0f, KNEE)
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oes)
        val pos = GLES30.glGetAttribLocation(p, "pos")
        GLES30.glEnableVertexAttribArray(pos)
        GLES30.glVertexAttribPointer(pos, 2, GLES30.GL_FLOAT, false, 0, quad)
        GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4)
    }

    private fun measure(timestampNs: Long) {
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, fbo)
        GLES30.glViewport(0, 0, MEASURE_W, MEASURE_H)
        draw(measureProgram, 0.2f, 0.2f, 0.6f, 0.6f)
        measureBuffer.position(0)
        GLES30.glReadPixels(0, 0, MEASURE_W, MEASURE_H, GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, measureBuffer)
        val bins = IntArray(BINS)
        for (i in 0 until MEASURE_W * MEASURE_H) {
            val y = (measureBuffer.get(i * 4).toInt() and 0xff) / 255f
            bins[minOf((y * 1024).toInt(), BINS - 1)]++
        }
        val want = (MEASURE_W * MEASURE_H + 99) / 100
        var sum = 0
        var bin = 0
        while (bin < BINS - 1) {
            sum += bins[bin]
            if (sum >= want) break
            bin++
        }
        val p1 = (bin + 0.5f) / 1024
        if (bin >= BINS - 1 || p1 >= NO_SHADOWS) return
        floor = if (floor < 0) p1 else {
            val dt = ((timestampNs - floorTimeNs) / 1e9).coerceIn(0.0, 1.0)
            floor + (p1 - floor) * minOf(1.0, dt / FLOOR_SECONDS).toFloat()
        }
        floorTimeNs = timestampNs
        val f = minOf(floor, FLOOR_MOST)
        val t = 1 - f / KNEE
        lift = if (f > BLACK_LANDS) (f - BLACK_LANDS) / (t * t) else 0f
    }

    private fun collectQueries() {
        val result = IntArray(1)
        while (queryTail < queryHead) {
            val q = queries[queryTail % queries.size]
            GLES30.glGetQueryObjectuiv(q, GLES30.GL_QUERY_RESULT_AVAILABLE, result, 0)
            if (result[0] == 0) break
            GLES30.glGetQueryObjectuiv(q, GLES30.GL_QUERY_RESULT, result, 0)
            if (gpuCount < gpuMs.size) gpuMs[gpuCount++] = (result[0].toLong() and 0xffffffffL) / 1e6f
            queryTail++
        }
    }

    private fun report() {
        val now = SystemClock.elapsedRealtime()
        if (now - windowStart < 2000) return
        val sorted = gpuMs.copyOf(gpuCount).sorted()
        val mean = if (sorted.isEmpty()) 0f else sorted.sum() / sorted.size
        val p95 = if (sorted.isEmpty()) 0f else sorted[minOf(sorted.size - 1, (sorted.size * 0.95).toInt())]
        Log.i(
            TAG,
            String.format(
                java.util.Locale.ROOT, "%dx%d from %dx%d %s, frames %d of %d decoded, %.2f fps, gpu_ms mean %.3f p95 %.3f, floor %.3f lift %.3f",
                outW, outH, srcW, srcH, currentScaler().name.lowercase(), frames, available, frames * 1000f / (now - windowStart), mean, p95,
                floor, lift,
            ),
        )
        readControls()
        frames = 0
        available = 0
        gpuCount = 0
        windowStart = now
    }

    private fun readControls() {
        val dir = view.context.getExternalFilesDir(null) ?: return
        java.io.File(dir, "lambent_scaler").takeIf { it.exists() }?.readText()?.trim()?.uppercase()?.let { name ->
            Scaler.values().firstOrNull { it.name == name }?.takeIf { it != scaler }?.let {
                scaler = it
                view.post { applySurfaceSize() }
            }
        }
        java.io.File(dir, "lambent_dump").takeIf { it.exists() }?.let {
            it.delete()
            dumpRequested = true
        }
    }

    private enum class Scaler { NATIVE, BILINEAR, CATROM, RAVU }

    /** [source] with `#define [name] 1` after its `#version` line. */
    private fun defined(source: String, name: String): String {
        val end = source.indexOf('\n') + 1
        return source.substring(0, end) + "#define $name 1\n" + source.substring(end)
    }

    private fun program(vs: String, fs: String): Int {
        val p = GLES30.glCreateProgram()
        for ((type, source) in listOf(GLES30.GL_VERTEX_SHADER to vs, GLES30.GL_FRAGMENT_SHADER to fs)) {
            val s = GLES30.glCreateShader(type)
            GLES30.glShaderSource(s, source)
            GLES30.glCompileShader(s)
            val ok = IntArray(1)
            GLES30.glGetShaderiv(s, GLES30.GL_COMPILE_STATUS, ok, 0)
            if (ok[0] == 0) {
                Log.e(TAG, "shader: ${GLES30.glGetShaderInfoLog(s)}")
                return 0
            }
            GLES30.glAttachShader(p, s)
        }
        GLES30.glLinkProgram(p)
        return p
    }

    companion object {
        private const val TAG = "LambentHdr"
        private const val EGL_GL_COLORSPACE_KHR = 0x309D
        private const val EGL_GL_COLORSPACE_BT2020_PQ_EXT = 0x3340
        private const val EGL_SMPTE2086_DISPLAY_PRIMARY_RX_EXT = 0x3341
        private const val EGL_SMPTE2086_MAX_LUMINANCE_EXT = 0x3349
        private const val EGL_SMPTE2086_MIN_LUMINANCE_EXT = 0x334A
        private const val EGL_CTA861_3_MAX_CONTENT_LIGHT_LEVEL_EXT = 0x3360
        private const val EGL_CTA861_3_MAX_FRAME_AVERAGE_LEVEL_EXT = 0x3361
        private const val METADATA_SCALE = 50000
        private const val EGL_COLOR_COMPONENT_TYPE_EXT = 0x3339
        private const val EGL_COLOR_COMPONENT_TYPE_FIXED_EXT = 0x333A
        private const val EGL_COLOR_COMPONENT_TYPE_FLOAT_EXT = 0x333B
        private const val EGL_OPENGL_ES3_BIT = 0x40
        private const val GL_TIME_ELAPSED_EXT = 0x88BF

        private const val MEASURE_W = 256
        private const val MEASURE_H = 144
        private const val BINS = 256
        private const val NO_SHADOWS = 0.15f
        private const val FLOOR_SECONDS = 8.0
        private const val FLOOR_MOST = 0.12f
        private const val BLACK_LANDS = 0.016f
        private const val KNEE = 0.5f

        private const val RAVU_ASSET = "shaders/ravu-lite-ar-r3.hook"
        private const val RAVU_MAX_FPS = 31f

        private const val VERTEX = """#version 300 es
in vec2 pos; uniform mat4 st; uniform vec4 crop; out vec2 uv; out vec2 tc;
void main() { vec2 t = crop.xy + (pos * 0.5 + 0.5) * crop.zw; tc = t; uv = (st * vec4(t, 0.0, 1.0)).xy; gl_Position = vec4(pos, 0.0, 1.0); }
"""

        private const val VERTEX_PLAIN = """#version 300 es
in vec2 pos; out vec2 uv;
void main() { uv = pos * 0.5 + 0.5; gl_Position = vec4(pos, 0.0, 1.0); }
"""

        private const val HEAD = """#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision highp float;
uniform samplerExternalOES tex; uniform vec2 deepen; in vec2 uv; in vec2 tc; out vec4 color;
"""

        // The picture pass, at the picture's size: R'G'B' with Deepen blacks' bend, Y' in alpha (what a LUMA prescaler reads). With
        // SHARPEN (the Catmull-Rom path), FSR's RCAS on the cross of neighbours first, at a light setting.
        private const val PREP = HEAD + """
uniform mat4 st; uniform vec2 srcPt;
vec3 at(vec2 o) { return clamp(texture(tex, (st * vec4(tc + o * srcPt, 0.0, 1.0)).xy).rgb, 0.0, 1.0); }
void main() {
  vec3 e = at(vec2(0.0));
#ifdef SHARPEN
  vec3 b = at(vec2(0.0, -1.0)), d = at(vec2(-1.0, 0.0)), f = at(vec2(1.0, 0.0)), h = at(vec2(0.0, 1.0));
  vec3 mn = min(min(b, d), min(f, h)), mx = max(max(b, d), max(f, h));
  vec3 hitMin = min(mn, e) / (4.0 * max(mx, e) + 1e-5);
  vec3 hitMax = (1.0 - max(mx, e)) / (4.0 * min(mn, e) - 4.0 - 1e-5);
  vec3 lobe3 = max(-hitMin, hitMax);
  float lobe = max(-0.1875, min(max(lobe3.r, max(lobe3.g, lobe3.b)), 0.0)) * 0.5;
  e = clamp((lobe * (b + d + f + h) + e) / (4.0 * lobe + 1.0), 0.0, 1.0);
#endif
  if (deepen.x > 0.0) { float y = dot(e, vec3(0.2126, 0.7152, 0.0722)); float t = clamp(1.0 - y / deepen.y, 0.0, 1.0);
    e *= y > 1e-4 ? clamp((y - deepen.x * t * t) / y, 0.0, 1.0) : 0.0; }
  color = vec4(e, dot(e, vec3(0.2126, 0.7152, 0.0722)));
}
"""

        private const val LIFT_FN = """
uniform float curve[65]; uniform float saturation;
vec3 pq(vec3 nits) { const float m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
  vec3 l = pow(clamp(nits / 10000.0, 0.0, 1.0), vec3(m1)); return pow((c1 + c2 * l) / (1.0 + c3 * l), vec3(m2)); }
float pq_nits(float e) { const float m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
  float p = pow(clamp(e, 0.0, 1.0), 1.0 / m2); return 10000.0 * pow(max(p - c1, 0.0) / (c2 - c3 * p), 1.0 / m1); }
vec3 lift(vec3 rgb) {
  vec3 lin = pow(rgb, vec3(2.4));
  float y = dot(lin, vec3(0.2126, 0.7152, 0.0722));
  float x = pow(y, 1.0 / 2.4) * 64.0; int i = min(int(x), 63);
  float nits = pq_nits(mix(curve[i], curve[i + 1], x - float(i)));
  vec3 o = lin * (y > 1e-7 ? nits / y : 0.0);
  float yo = dot(o, vec3(0.2126, 0.7152, 0.0722));
  o = max(yo + (o - yo) * (0.985 * saturation), 0.0);
  const mat3 to2020 = mat3(vec3(0.6274, 0.0691, 0.0164), vec3(0.3293, 0.9195, 0.0880), vec3(0.0433, 0.0114, 0.8956));
  return pq(to2020 * o);
}
"""

        // The last pass, at the screen's size: the picture scaled (bilinear; Catmull-Rom in nine bilinear taps; or RAVU-lite's doubled
        // Y' with the picture's chroma, as R'G'B' plus the luma detail), then the lift.
        private const val FINAL = """#version 300 es
precision highp float;
uniform sampler2D picture; uniform sampler2D luma2x; uniform vec2 srcSize; in vec2 uv; out vec4 color;
""" + LIFT_FN + """
vec4 catrom(vec2 p) {
  vec2 sp = p * srcSize; vec2 t1 = floor(sp - 0.5) + 0.5; vec2 f = sp - t1;
  vec2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f)); vec2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
  vec2 w2 = f * (0.5 + f * (2.0 - 1.5 * f)); vec2 w3 = f * f * (-0.5 + 0.5 * f);
  vec2 w12 = w1 + w2; vec2 t0 = (t1 - 1.0) / srcSize; vec2 t3 = (t1 + 2.0) / srcSize; vec2 t12 = (t1 + w2 / w12) / srcSize;
  vec4 r = texture(picture, vec2(t0.x, t0.y)) * w0.x * w0.y + texture(picture, vec2(t12.x, t0.y)) * w12.x * w0.y
         + texture(picture, vec2(t3.x, t0.y)) * w3.x * w0.y + texture(picture, vec2(t0.x, t12.y)) * w0.x * w12.y
         + texture(picture, vec2(t12.x, t12.y)) * w12.x * w12.y + texture(picture, vec2(t3.x, t12.y)) * w3.x * w12.y
         + texture(picture, vec2(t0.x, t3.y)) * w0.x * w3.y + texture(picture, vec2(t12.x, t3.y)) * w12.x * w3.y
         + texture(picture, vec2(t3.x, t3.y)) * w3.x * w3.y;
  return r;
}
void main() {
#if defined(CATROM)
  vec3 rgb = catrom(uv).rgb;
#elif defined(RAVU)
  vec4 lo = texture(picture, uv);
  vec3 rgb = lo.rgb + (texture(luma2x, uv).r - lo.a);
#else
  vec3 rgb = texture(picture, uv).rgb;
#endif
  color = vec4(lift(clamp(rgb, 0.0, 1.0)), 1.0);
}
"""

        private const val MEASURE = HEAD + """
void main() { color = vec4(dot(texture(tex, uv).rgb, vec3(0.2126, 0.7152, 0.0722)), 0.0, 0.0, 1.0); }
"""

        // Lambent's InverseToneMap.swift `expand` on the sampler's R'G'B', after Deepen blacks' bend.
        private const val LIFT = HEAD + """
uniform float curve[65]; uniform float saturation;
vec3 pq(vec3 nits) { const float m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
  vec3 l = pow(clamp(nits / 10000.0, 0.0, 1.0), vec3(m1)); return pow((c1 + c2 * l) / (1.0 + c3 * l), vec3(m2)); }
float pq_nits(float e) { const float m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
  float p = pow(clamp(e, 0.0, 1.0), 1.0 / m2); return 10000.0 * pow(max(p - c1, 0.0) / (c2 - c3 * p), 1.0 / m1); }
void main() {
  vec3 rgb = clamp(texture(tex, uv).rgb, 0.0, 1.0);
  if (deepen.x > 0.0) { float y = dot(rgb, vec3(0.2126, 0.7152, 0.0722)); float t = clamp(1.0 - y / deepen.y, 0.0, 1.0);
    rgb *= y > 1e-4 ? clamp((y - deepen.x * t * t) / y, 0.0, 1.0) : 0.0; }
  vec3 lin = pow(rgb, vec3(2.4));
  float y = dot(lin, vec3(0.2126, 0.7152, 0.0722));
  float x = pow(y, 1.0 / 2.4) * 64.0; int i = min(int(x), 63);
  float nits = pq_nits(mix(curve[i], curve[i + 1], x - float(i)));
  vec3 o = lin * (y > 1e-7 ? nits / y : 0.0);
  float yo = dot(o, vec3(0.2126, 0.7152, 0.0722));
  o = max(yo + (o - yo) * (0.985 * saturation), 0.0);
  const mat3 to2020 = mat3(vec3(0.6274, 0.0691, 0.0164), vec3(0.3293, 0.9195, 0.0880), vec3(0.0433, 0.0114, 0.8956));
  color = vec4(pq(to2020 * o), 1.0);
}
"""
    }
}
