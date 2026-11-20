package org.moonfin.nativevideo

import android.content.Context
import android.opengl.GLES11Ext
import android.opengl.GLES30
import android.opengl.GLES31
import android.util.Log
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

/**
 * Lambent Auto HDR's bank of sixteen tables (Lambent's companion/shaders/lutg; docs/HDR_FALLBACK.md) on an Android TV's GPU: the Apple
 * players' LambentAutoHDR.swift kernels, one for one, as GLES 3.1 compute shaders. Checked on a Shield Pro against Lambent's reference.py
 * (2026-11-17, Lambent's companion/spikes/android-hdr-probe on branch shield-tables): weights within 0.006, the table 0.21 10-bit codes off
 * on average. Per picture, before the lift reads it ([encode]): its 8 x 8 means (a fragment pass over the decoder's texture), stretched to
 * the 240 x 135 thumbnail the network was trained on, HDRTVNet's condition CNN (five blocks of 1x1 convolution, 3x3 average at stride 2,
 * leaky ReLU, four instance norms), a linear layer to the sixteen tables' weights, the tables (33^3, a correction in PQ) mixed by them,
 * and a 65^3 RGBA16F table of BT.2408 plus the correction, BT.2020 PQ over the picture's R'G'B', which the lift samples trilinearly
 * ([LIFT_LOOKUP]). The weights are the app's assets `lambent_autohdr/agcm.json` and `agcm.bin` (git-ignored, copied by
 * tvos/scripts/copy_autohdr_weights.sh with `--android`); without them there is no Auto HDR here ([available]).
 *
 * Needs a current GLES 3.1 context. `external`: the picture is a SurfaceTexture's (samplerExternalOES); else a plain 2D texture (the bench).
 */
internal class LambentAutoHdrBank private constructor(blob: ByteBuffer, arrays: JSONObject, private val external: Boolean) {
    /** The picture's table, for the lift: a 3D texture, linear. */
    val lut: Int
    private val meansFbo: Int
    private var meansTex = 0
    private var meansW = 0
    private var meansH = 0
    private val meansProg: Int
    private val thumbProg: Int
    private val poolProg: Int
    private val blockProg: Int
    private val statsProg: Int
    private val foldProg: Int
    private val mixProg: Int
    private val tableProg: Int
    private val weights: Int
    private val act0: Int
    private val act1: Int
    private val scratch: Int
    private val stats: Int
    private val folded: Int
    private val mixed: Int
    private val offsets = HashMap<String, Int>()
    private val quad: FloatBuffer = ByteBuffer.allocateDirect(32).order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
        put(floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f)).position(0)
    }

    init {
        val defines = StringBuilder()
        for (name in arrays.keys()) {
            val off = arrays.getJSONObject(name).getInt("offset")
            offsets[name] = off
            defines.append("#define OFF_").append(name.replace('.', '_')).append(' ').append(off).append("u\n")
        }
        val b = IntArray(7)
        GLES30.glGenBuffers(7, b, 0)
        weights = b[0]; act0 = b[1]; act1 = b[2]; scratch = b[3]; stats = b[4]; folded = b[5]; mixed = b[6]
        buffer(weights, blob.capacity(), blob)
        var most = 3 * TW * TH
        var h = TH
        var w = TW
        for (i in 0 until 5) {
            h = (h - 1) / 2 + 1
            w = (w - 1) / 2 + 1
            most = maxOf(most, CHANNELS[i + 1] * h * w)
        }
        buffer(act0, most * 4, null)
        buffer(act1, most * 4, null)
        buffer(scratch, most * 4, null)
        buffer(stats, 128 * 8, null)
        buffer(folded, 16 * 4, null)
        buffer(mixed, S * S * S * 16, null)
        val t = IntArray(1)
        GLES30.glGenTextures(1, t, 0)
        lut = t[0]
        GLES30.glBindTexture(GLES30.GL_TEXTURE_3D, lut)
        GLES30.glTexStorage3D(GLES30.GL_TEXTURE_3D, 1, GLES30.GL_RGBA16F, GRID, GRID, GRID)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_3D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_3D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
        for (p in intArrayOf(GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_TEXTURE_WRAP_R)) {
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_3D, p, GLES30.GL_CLAMP_TO_EDGE)
        }
        GLES30.glGenFramebuffers(1, t, 0)
        meansFbo = t[0]
        meansProg = program(VS, if (external) MEANS_FS_EXTERNAL else MEANS_FS_2D)
        val head = "#version 310 es\nprecision highp float;\nprecision highp int;\n$defines$COMMON"
        thumbProg = compute(head + THUMB)
        poolProg = compute(head + POOL9)
        blockProg = compute(head + BLOCK)
        statsProg = compute(head + STATS)
        foldProg = compute(head + FOLD)
        mixProg = compute(head + MIX)
        tableProg = compute(head + TABLE)
    }

    /** This picture's table into [lut]: `picture` its texture (`stm` the SurfaceTexture's transform, or identity), `w` x `h` its size. */
    fun encode(picture: Int, stm: FloatArray, w: Int, h: Int) {
        val iw = (w + 7) / 8
        val ih = (h + 7) / 8
        if (iw != meansW || ih != meansH) {
            if (meansTex != 0) GLES30.glDeleteTextures(1, intArrayOf(meansTex), 0)
            val t = IntArray(1)
            GLES30.glGenTextures(1, t, 0)
            meansTex = t[0]
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, meansTex)
            GLES30.glTexStorage2D(GLES30.GL_TEXTURE_2D, 1, GLES30.GL_RGBA32F, iw, ih)
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, meansFbo)
            GLES30.glFramebufferTexture2D(GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0, GLES30.GL_TEXTURE_2D, meansTex, 0)
            meansW = iw
            meansH = ih
        }
        // 1. The 8 x 8 means: a SurfaceTexture's at its texel centres (nearest; the lift's linear filter is put back after), a plain
        // texture's by linear reads on the corners of four texels.
        val target = if (external) GLES11Ext.GL_TEXTURE_EXTERNAL_OES else GLES30.GL_TEXTURE_2D
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, meansFbo)
        GLES30.glViewport(0, 0, iw, ih)
        GLES30.glUseProgram(meansProg)
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        GLES30.glBindTexture(target, picture)
        if (external) {
            GLES30.glTexParameteri(target, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_NEAREST)
            GLES30.glTexParameteri(target, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_NEAREST)
        }
        GLES30.glUniform1i(GLES30.glGetUniformLocation(meansProg, "tex"), 0)
        GLES30.glUniformMatrix4fv(GLES30.glGetUniformLocation(meansProg, "st"), 1, false, stm, 0)
        GLES30.glUniform2f(GLES30.glGetUniformLocation(meansProg, "src"), w.toFloat(), h.toFloat())
        drawQuad(meansProg)
        GLES30.glTexParameteri(target, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(target, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)

        // 2. The thumbnail.
        GLES30.glUseProgram(thumbProg)
        GLES30.glActiveTexture(GLES30.GL_TEXTURE1)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, meansTex)
        u(thumbProg, "means", 1)
        u(thumbProg, "iw", iw)
        u(thumbProg, "ih", ih)
        bind(2, act0)
        GLES31.glDispatchCompute((TW + 15) / 16, (TH + 15) / 16, 1)
        barrier()
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)

        // 3. The condition CNN.
        var h2 = TH
        var w2 = TW
        val acts = intArrayOf(act0, act1)
        var at = 0
        bind(3, stats)
        bind(4, weights)
        for (blk in 0 until 5) {
            val ci = CHANNELS[blk]
            val co = CHANNELS[blk + 1]
            val oh = (h2 - 1) / 2 + 1
            val ow = (w2 - 1) / 2 + 1
            GLES30.glUseProgram(poolProg)
            u(poolProg, "ci", ci); u(poolProg, "ih", h2); u(poolProg, "iw", w2); u(poolProg, "oh", oh); u(poolProg, "ow", ow)
            u(poolProg, "normIn", if (blk > 0) 1 else 0)
            u(poolProg, "offG", if (blk > 0) offsets.getValue("norm${blk - 1}.weight") else 0)
            u(poolProg, "offBeta", if (blk > 0) offsets.getValue("norm${blk - 1}.bias") else 0)
            bind(1, acts[at])
            bind(2, scratch)
            GLES31.glDispatchCompute((ow + 7) / 8, (oh + 7) / 8, ci)
            barrier()
            GLES30.glUseProgram(blockProg)
            u(blockProg, "ci", ci); u(blockProg, "co", co); u(blockProg, "ih", h2); u(blockProg, "iw", w2)
            u(blockProg, "oh", oh); u(blockProg, "ow", ow)
            u(blockProg, "offW", offsets.getValue("cond$blk.weight"))
            u(blockProg, "offB", offsets.getValue("cond$blk.bias"))
            bind(1, scratch)
            bind(2, acts[1 - at])
            GLES31.glDispatchCompute((ow + 7) / 8, (oh + 7) / 8, co)
            barrier()
            if (blk < 4) {
                GLES30.glUseProgram(statsProg)
                u(statsProg, "n", oh * ow)
                GLES31.glDispatchCompute(co, 1, 1)
                barrier()
            }
            h2 = oh
            w2 = ow
            at = 1 - at
        }
        // 4. The sixteen weights, the tables mixed, the 65^3 table.
        GLES30.glUseProgram(foldProg)
        u(foldProg, "n", h2 * w2)
        bind(1, acts[at])
        bind(5, folded)
        GLES31.glDispatchCompute(1, 1, 1)
        barrier()
        GLES30.glUseProgram(mixProg)
        bind(6, mixed)
        GLES31.glDispatchCompute((S * S * S + 255) / 256, 1, 1)
        barrier()
        GLES30.glUseProgram(tableProg)
        GLES31.glBindImageTexture(0, lut, 0, true, 0, GLES31.GL_WRITE_ONLY, GLES30.GL_RGBA16F)
        GLES31.glDispatchCompute((GRID + 3) / 4, (GRID + 3) / 4, (GRID + 3) / 4)
        GLES31.glMemoryBarrier(GLES31.GL_TEXTURE_FETCH_BARRIER_BIT)
    }

    private val locations = HashMap<Int, HashMap<String, Int>>()

    /** A uniform by name, its location looked up once (dozens a picture otherwise). */
    private fun u(prog: Int, name: String, v: Int) =
        GLES30.glUniform1i(locations.getOrPut(prog) { HashMap() }.getOrPut(name) { GLES30.glGetUniformLocation(prog, name) }, v)

    fun release() {
        GLES30.glDeleteBuffers(7, intArrayOf(weights, act0, act1, scratch, stats, folded, mixed), 0)
        GLES30.glDeleteTextures(2, intArrayOf(lut, meansTex), 0)
        GLES30.glDeleteFramebuffers(1, intArrayOf(meansFbo), 0)
        for (p in intArrayOf(meansProg, thumbProg, poolProg, blockProg, statsProg, foldProg, mixProg, tableProg)) GLES30.glDeleteProgram(p)
    }

    private fun drawQuad(prog: Int) {
        val pos = GLES30.glGetAttribLocation(prog, "pos")
        GLES30.glEnableVertexAttribArray(pos)
        GLES30.glVertexAttribPointer(pos, 2, GLES30.GL_FLOAT, false, 0, quad)
        GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4)
    }

    companion object {
        const val TAG = "LambentAutoHdr"
        private val CHANNELS = intArrayOf(3, 16, 32, 64, 128, 128)
        private const val TW = 240
        private const val TH = 135
        private const val S = 33
        const val GRID = 65
        private const val ASSET_DIR = "lambent_autohdr"

        /** The weights are in the app. */
        fun available(context: Context): Boolean =
            runCatching { context.assets.list(ASSET_DIR)?.toSet()?.containsAll(listOf("agcm.json", "agcm.bin")) == true }.getOrDefault(false)

        /** The bank, built in the current context; null without its weights or when a shader would not build. */
        fun create(context: Context, external: Boolean): LambentAutoHdrBank? = try {
            val manifest = JSONObject(context.assets.open("$ASSET_DIR/agcm.json").use { String(it.readBytes(), Charsets.UTF_8) })
            check(manifest.optString("network") == "lutg") { "agcm.json is not the bank of sixteen tables" }
            val bytes = context.assets.open("$ASSET_DIR/agcm.bin").use { it.readBytes() }
            val blob = ByteBuffer.allocateDirect(bytes.size).order(ByteOrder.nativeOrder()).put(bytes).also { it.position(0) }
            linkFailed = false
            LambentAutoHdrBank(blob, manifest.getJSONObject("arrays"), external).takeIf { built ->
                GLES30.glGetError() == GLES30.GL_NO_ERROR && built.allLinked
            }
        } catch (e: Exception) {
            Log.w(TAG, "no bank of tables: ${e.message}")
            null
        }

        private var linkFailed = false

        private fun buffer(id: Int, bytes: Int, data: ByteBuffer?) {
            GLES30.glBindBuffer(GLES31.GL_SHADER_STORAGE_BUFFER, id)
            GLES30.glBufferData(GLES31.GL_SHADER_STORAGE_BUFFER, bytes, data, GLES30.GL_STATIC_DRAW)
        }

        private fun compute(src: String): Int {
            val s = GLES30.glCreateShader(GLES31.GL_COMPUTE_SHADER)
            GLES30.glShaderSource(s, src)
            GLES30.glCompileShader(s)
            val ok = IntArray(1)
            GLES30.glGetShaderiv(s, GLES30.GL_COMPILE_STATUS, ok, 0)
            if (ok[0] == 0) { Log.e(TAG, "compute shader: ${GLES30.glGetShaderInfoLog(s)}"); linkFailed = true }
            val p = GLES30.glCreateProgram()
            GLES30.glAttachShader(p, s)
            GLES30.glLinkProgram(p)
            GLES30.glDeleteShader(s)
            GLES30.glGetProgramiv(p, GLES30.GL_LINK_STATUS, ok, 0)
            if (ok[0] == 0) { Log.e(TAG, "compute link: ${GLES30.glGetProgramInfoLog(p)}"); linkFailed = true }
            return p
        }

        fun program(vs: String, fs: String): Int {
            val p = GLES30.glCreateProgram()
            for ((type, src) in listOf(GLES30.GL_VERTEX_SHADER to vs, GLES30.GL_FRAGMENT_SHADER to fs)) {
                val s = GLES30.glCreateShader(type)
                GLES30.glShaderSource(s, src)
                GLES30.glCompileShader(s)
                val ok = IntArray(1)
                GLES30.glGetShaderiv(s, GLES30.GL_COMPILE_STATUS, ok, 0)
                if (ok[0] == 0) { Log.e(TAG, "shader: ${GLES30.glGetShaderInfoLog(s)}"); linkFailed = true }
                GLES30.glAttachShader(p, s)
                GLES30.glDeleteShader(s)
            }
            GLES30.glLinkProgram(p)
            val ok = IntArray(1)
            GLES30.glGetProgramiv(p, GLES30.GL_LINK_STATUS, ok, 0)
            if (ok[0] == 0) { Log.e(TAG, "link: ${GLES30.glGetProgramInfoLog(p)}"); linkFailed = true }
            return p
        }

        private fun bind(binding: Int, buf: Int) = GLES30.glBindBufferBase(GLES31.GL_SHADER_STORAGE_BUFFER, binding, buf)


        private fun barrier() = GLES31.glMemoryBarrier(GLES31.GL_SHADER_STORAGE_BARRIER_BIT)

        val IDENTITY = floatArrayOf(1f, 0f, 0f, 0f, 0f, 1f, 0f, 0f, 0f, 0f, 1f, 0f, 0f, 0f, 0f, 1f)

        /** The full-screen quad; `uv` is the picture's coordinate through `st` (the SurfaceTexture's transform). */
        const val VS = "#version 300 es\n" +
            "in vec2 pos; uniform mat4 st; out vec2 uv;\n" +
            "void main() { vec2 t = pos * 0.5 + 0.5; uv = (st * vec4(t, 0.0, 1.0)).xy; gl_Position = vec4(pos, 0.0, 1.0); }\n"

        /** The lift's read of the picture's table at its R'G'B': the table's points on the 65-point grid's texel centres. */
        const val LIFT_LOOKUP = "vec3 lifted(vec3 rgb) { return texture(lut, clamp(rgb, 0.0, 1.0) * (64.0 / 65.0) + 0.5 / 65.0).rgb; }\n"

        private const val MEANS_BODY = "uniform mat4 st; uniform vec2 src; in vec2 uv; out vec4 color;\n" +
            "void main() {\n" +
            "  ivec2 b = ivec2(gl_FragCoord.xy); vec3 sum = vec3(0.0);\n" +
            "  for (int y = 0; y < 8; y++) for (int x = 0; x < 8; x++) {\n" +
            "    vec2 p = vec2(float(min(b.x * 8 + x, int(src.x) - 1)), float(min(b.y * 8 + y, int(src.y) - 1))) + 0.5;\n" +
            "    vec2 t = vec2(p.x / src.x, 1.0 - p.y / src.y);\n" +
            "    sum += clamp(texture(tex, (st * vec4(t, 0.0, 1.0)).xy).rgb, 0.0, 1.0);\n" +
            "  }\n" +
            "  color = vec4(sum / 64.0, 1.0);\n" +
            "}\n"

        // The 8 x 8 means of the picture's R'G'B' (the edge repeated), row 0 the picture's top.
        private const val MEANS_FS_EXTERNAL = "#version 300 es\n#extension GL_OES_EGL_image_external_essl3 : require\nprecision highp float;\n" +
            "uniform samplerExternalOES tex;\n" + MEANS_BODY
        // A plain texture filtered linearly: a read on the corner of four texels is their exact mean, so a whole 8 x 8 block is 16 reads
        // (64 one by one took 4.5 ms of a Shield's 7.7 ms table at 1080p). Blocks on a ragged edge read texel by texel, the edge repeated.
        private const val MEANS_FS_2D = "#version 300 es\nprecision highp float;\nuniform highp sampler2D tex;\n" +
            "uniform mat4 st; uniform vec2 src; in vec2 uv; out vec4 color;\n" +
            "void main() {\n" +
            "  ivec2 b = ivec2(gl_FragCoord.xy), last = ivec2(src) - 1; vec3 sum = vec3(0.0);\n" +
            "  if (b.x * 8 + 7 <= last.x && b.y * 8 + 7 <= last.y) {\n" +
            "    for (int y = 0; y < 4; y++) for (int x = 0; x < 4; x++) {\n" +
            "      vec2 p = vec2(b * 8 + ivec2(x, y) * 2) + 1.0;\n" +
            "      sum += clamp(texture(tex, vec2(p.x / src.x, 1.0 - p.y / src.y)).rgb, 0.0, 1.0);\n" +
            "    }\n" +
            "    color = vec4(sum / 16.0, 1.0);\n" +
            "    return;\n" +
            "  }\n" +
            "  for (int y = 0; y < 8; y++) for (int x = 0; x < 8; x++) {\n" +
            "    vec2 p = vec2(float(min(b.x * 8 + x, last.x)), float(min(b.y * 8 + y, last.y))) + 0.5;\n" +
            "    sum += clamp(texture(tex, vec2(p.x / src.x, 1.0 - p.y / src.y)).rgb, 0.0, 1.0);\n" +
            "  }\n" +
            "  color = vec4(sum / 64.0, 1.0);\n" +
            "}\n"

        private const val COMMON = "vec3 pqf(vec3 nits) { const float m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;\n" +
            "  vec3 l = pow(clamp(nits / 10000.0, 0.0, 1.0), vec3(m1)); return pow((c1 + c2 * l) / (1.0 + c3 * l), vec3(m2)); }\n" +
            "vec3 bt2408(vec3 rgb) { const mat3 to2020 = mat3(vec3(0.6274, 0.0691, 0.0164), vec3(0.3293, 0.9195, 0.0880), vec3(0.0433, 0.0114, 0.8956));\n" +
            "  return pqf(to2020 * pow(rgb, vec3(2.4)) * 203.0); }\n"

        private const val THUMB = "layout(local_size_x = 16, local_size_y = 16) in;\n" +
            "uniform highp sampler2D means; uniform int iw, ih;\n" +
            "layout(std430, binding = 2) writeonly buffer Dst { float dst[]; };\n" +
            "void main() {\n" +
            "  uvec2 id = gl_GlobalInvocationID.xy; const int tw = 240, th = 135; if (id.x >= uint(tw) || id.y >= uint(th)) return;\n" +
            "  float sx = max((float(id.x) + 0.5) * float(iw) / float(tw) - 0.5, 0.0), sy = max((float(id.y) + 0.5) * float(ih) / float(th) - 0.5, 0.0);\n" +
            "  int x0 = min(int(sx), iw - 1), y0 = min(int(sy), ih - 1), x1 = min(x0 + 1, iw - 1), y1 = min(y0 + 1, ih - 1);\n" +
            "  float fx = sx - float(x0), fy = sy - float(y0);\n" +
            "  vec3 m = mix(mix(texelFetch(means, ivec2(x0, y0), 0).rgb, texelFetch(means, ivec2(x1, y0), 0).rgb, fx),\n" +
            "               mix(texelFetch(means, ivec2(x0, y1), 0).rgb, texelFetch(means, ivec2(x1, y1), 0).rgb, fx), fy);\n" +
            "  uint plane = uint(tw * th), i = id.y * uint(tw) + id.x;\n" +
            "  dst[i] = m.r; dst[plane + i] = m.g; dst[2u * plane + i] = m.b;\n" +
            "}\n"

        private const val POOL9 = "layout(local_size_x = 8, local_size_y = 8) in;\n" +
            "uniform int ci, ih, iw, oh, ow, normIn, offG, offBeta;\n" +
            "layout(std430, binding = 1) readonly buffer Src { float src[]; };\n" +
            "layout(std430, binding = 2) writeonly buffer Dst { float dst[]; };\n" +
            "layout(std430, binding = 3) readonly buffer Stats { vec2 stats[]; };\n" +
            "layout(std430, binding = 4) readonly buffer W { float wts[]; };\n" +
            "void main() {\n" +
            "  uvec3 id = gl_GlobalInvocationID; if (id.x >= uint(ow) || id.y >= uint(oh) || id.z >= uint(ci)) return;\n" +
            "  uint c = id.z, plane = uint(ih * iw);\n" +
            "  vec2 s = normIn != 0 ? stats[c] : vec2(0.0, 1.0);\n" +
            "  float g = normIn != 0 ? wts[uint(offG) + c] * s.y : 1.0, beta = normIn != 0 ? wts[uint(offBeta) + c] - s.x * g : 0.0;\n" +
            "  float sum = 0.0;\n" +
            "  for (int dy = 0; dy < 3; dy++) for (int dx = 0; dx < 3; dx++) {\n" +
            "    int y = int(id.y) * 2 - 1 + dy, x = int(id.x) * 2 - 1 + dx;\n" +
            "    if (y >= 0 && x >= 0 && y < ih && x < iw) sum += src[c * plane + uint(y * iw + x)] * g + beta;\n" +
            "  }\n" +
            "  dst[c * uint(oh * ow) + id.y * uint(ow) + id.x] = sum / 9.0;\n" +
            "}\n"

        private const val BLOCK = "layout(local_size_x = 8, local_size_y = 8) in;\n" +
            "uniform int ci, co, ih, iw, oh, ow, offW, offB;\n" +
            "layout(std430, binding = 1) readonly buffer Src { float src[]; };\n" +
            "layout(std430, binding = 2) writeonly buffer Dst { float dst[]; };\n" +
            "layout(std430, binding = 4) readonly buffer W { float wts[]; };\n" +
            "void main() {\n" +
            "  uvec3 id = gl_GlobalInvocationID; if (id.x >= uint(ow) || id.y >= uint(oh) || id.z >= uint(co)) return;\n" +
            "  uint o = id.z, n = uint(oh * ow), here = id.y * uint(ow) + id.x;\n" +
            "  int y0 = int(id.y) * 2 - 1, x0 = int(id.x) * 2 - 1;\n" +
            "  float inside = float((min(y0 + 3, ih) - max(y0, 0)) * (min(x0 + 3, iw) - max(x0, 0)));\n" +
            "  float acc = wts[uint(offB) + o] * inside / 9.0;\n" +
            "  for (uint c = 0u; c < uint(ci); c++) acc += wts[uint(offW) + o * uint(ci) + c] * src[c * n + here];\n" +
            "  dst[o * n + here] = acc > 0.0 ? acc : 0.2 * acc;\n" +
            "}\n"

        private const val STATS = "layout(local_size_x = 256) in;\n" +
            "uniform int n;\n" +
            "layout(std430, binding = 2) readonly buffer Dst { float dst[]; };\n" +
            "layout(std430, binding = 3) writeonly buffer Stats { vec2 stats[]; };\n" +
            "shared float red[256];\n" +
            "void main() {\n" +
            "  uint c = gl_WorkGroupID.x, t = gl_LocalInvocationID.x, nn = uint(n);\n" +
            "  float sum = 0.0; for (uint i = t; i < nn; i += 256u) sum += dst[c * nn + i];\n" +
            "  red[t] = sum; barrier();\n" +
            "  for (uint s = 128u; s > 0u; s >>= 1) { if (t < s) red[t] += red[t + s]; barrier(); }\n" +
            "  float mean = red[0] / float(nn), sq = 0.0; barrier();\n" +
            "  for (uint i = t; i < nn; i += 256u) { float d = dst[c * nn + i] - mean; sq += d * d; }\n" +
            "  red[t] = sq; barrier();\n" +
            "  for (uint s = 128u; s > 0u; s >>= 1) { if (t < s) red[t] += red[t + s]; barrier(); }\n" +
            "  if (t == 0u) stats[c] = vec2(mean, inversesqrt(red[0] / float(nn) + 1e-5));\n" +
            "}\n"

        private const val FOLD = "layout(local_size_x = 256) in;\n" +
            "uniform int n;\n" +
            "layout(std430, binding = 1) readonly buffer Src { float src[]; };\n" +
            "layout(std430, binding = 4) readonly buffer W { float wts[]; };\n" +
            "layout(std430, binding = 5) writeonly buffer Folded { vec4 folded[]; };\n" +
            "shared float cond[32]; shared float mixedw[16];\n" +
            "void main() {\n" +
            "  uint t = gl_LocalInvocationID.x, nn = uint(n);\n" +
            "  if (t < 32u) { float sum = 0.0;\n" +
            "    for (uint q = 0u; q < nn; q++) { float z = wts[OFF_cond5_bias + t];\n" +
            "      for (uint c = 0u; c < 128u; c++) z += wts[OFF_cond5_weight + t * 128u + c] * src[c * nn + q];\n" +
            "      sum += z; }\n" +
            "    cond[t] = sum / float(nn); }\n" +
            "  barrier();\n" +
            "  if (t < 16u) { float a = wts[OFF_mix_bias + t]; for (uint k = 0u; k < 32u; k++) a += wts[OFF_mix_weight + t * 32u + k] * cond[k]; mixedw[t] = a; }\n" +
            "  barrier();\n" +
            "  if (t < 4u) folded[t] = vec4(mixedw[t * 4u], mixedw[t * 4u + 1u], mixedw[t * 4u + 2u], mixedw[t * 4u + 3u]);\n" +
            "}\n"

        private const val MIX = "layout(local_size_x = 256) in;\n" +
            "layout(std430, binding = 4) readonly buffer W { float wts[]; };\n" +
            "layout(std430, binding = 5) readonly buffer Folded { vec4 folded[]; };\n" +
            "layout(std430, binding = 6) writeonly buffer Mixed { vec4 mixed[]; };\n" +
            "void main() {\n" +
            "  const uint cube = 33u * 33u * 33u; uint gid = gl_GlobalInvocationID.x; if (gid >= cube) return;\n" +
            "  vec3 sum = vec3(0.0);\n" +
            "  for (uint k = 0u; k < 16u; k++) { uint base = OFF_tables + k * 3u * cube + gid;\n" +
            "    sum += folded[k / 4u][k % 4u] * vec3(wts[base], wts[base + cube], wts[base + 2u * cube]); }\n" +
            "  mixed[gid] = vec4(sum, 0.0);\n" +
            "}\n"

        private const val TABLE = "layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;\n" +
            "layout(std430, binding = 6) readonly buffer Mixed { vec4 mixed[]; };\n" +
            "layout(rgba16f, binding = 0) writeonly uniform highp image3D table;\n" +
            "void main() {\n" +
            "  uvec3 gid = gl_GlobalInvocationID; if (any(greaterThanEqual(gid, uvec3(65u)))) return;\n" +
            "  vec3 x = vec3(gid) / 64.0; const uint S = 33u; vec3 g = x * float(S - 1u);\n" +
            "  uvec3 i0 = uvec3(min(floor(g), vec3(float(S - 2u)))); vec3 f = g - vec3(i0), o = vec3(0.0);\n" +
            "  for (uint d = 0u; d < 8u; d++) {\n" +
            "    uvec3 off = uvec3(d >> 2, (d >> 1) & 1u, d & 1u), at = i0 + off;\n" +
            "    float w = (off.x != 0u ? f.x : 1.0 - f.x) * (off.y != 0u ? f.y : 1.0 - f.y) * (off.z != 0u ? f.z : 1.0 - f.z);\n" +
            "    o += w * mixed[(at.z * S + at.y) * S + at.x].xyz;\n" +
            "  }\n" +
            "  imageStore(table, ivec3(gid), vec4(clamp(bt2408(x) + o, 0.0, 1.0), 1.0));\n" +
            "}\n"
    }

    /** Every program built and linked. */
    private val allLinked: Boolean get() = !linkFailed
}
