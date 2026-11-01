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
 * All GL work runs on its own thread. Logs `LambentHdr` every 2 s.
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
        view.post {
            view.holder.setFixedSize(width, height)
        }
        gl.post { surfaceTexture?.setDefaultBufferSize(width, height) }
    }

    fun release() {
        isReady = false
        view.holder.removeCallback(this)
        gl.post {
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
        if (program == 0 || measureProgram == 0) return false
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
        Log.i(TAG, "ready: ${if (fp16) "fp16" else "10-bit"} BT.2020 PQ, deepen blacks ${if (deepenBlacks) "on" else "off"}")
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
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
        GLES30.glViewport(0, 0, outW, outH)
        val timed = queryHead - queryTail < queries.size
        if (timed) GLES30.glBeginQuery(GL_TIME_ELAPSED_EXT, queries[queryHead % queries.size])
        draw(program, 0f, 0f, 1f, 1f)
        if (timed) {
            GLES30.glEndQuery(GL_TIME_ELAPSED_EXT)
            queryHead++
        }
        collectQueries()
        EGL14.eglSwapBuffers(dpy, window)
        frames++
        report()
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
                java.util.Locale.ROOT, "%dx%d frames %d of %d decoded, %.2f fps, gpu_ms mean %.3f p95 %.3f, floor %.3f lift %.3f",
                outW, outH, frames, available, frames * 1000f / (now - windowStart), mean, p95, floor, lift,
            ),
        )
        frames = 0
        available = 0
        gpuCount = 0
        windowStart = now
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

        private const val VERTEX = """#version 300 es
in vec2 pos; uniform mat4 st; uniform vec4 crop; out vec2 uv;
void main() { vec2 t = crop.xy + (pos * 0.5 + 0.5) * crop.zw; uv = (st * vec4(t, 0.0, 1.0)).xy; gl_Position = vec4(pos, 0.0, 1.0); }
"""

        private const val HEAD = """#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision highp float;
uniform samplerExternalOES tex; uniform vec2 deepen; in vec2 uv; out vec4 color;
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
