package org.moonfin.nativevideo

import android.opengl.GLES30
import android.util.Log
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * An mpv user shader (`//!` directives) loaded at run time and compiled for GLES 3, as Lambent's hook2native.py does for Metal and
 * Direct3D (companion/shaders in Lambent). The shader file ships as a separate asset (`shaders/`, with its licence and NOTICE.txt), so
 * the app contains none of its code and anyone can replace it.
 *
 * Only what a LUMA prescaler such as RAVU-lite needs is handled: fragment-style passes (`vec4 hook()`) hooked on LUMA, `BIND`, `SAVE`,
 * `WIDTH` / `HEIGHT` as `n HOOKED.w *`, `<NAME>_tex`, `<NAME>_texOff`, `<NAME>_pos`, `<NAME>_size`, `<NAME>_pt`, and the shader's own
 * textures (hex, 32-bit floats or halves). `HOOKED` is the stage's picture texture, whose alpha holds Y'; the last pass's result is Y'
 * at its own size. `WHEN` is not evaluated: the stage decides when to run the shader (a 2x prescaler, run when the output is at least
 * 1.414 times the picture, as RAVU's `WHEN` says).
 */
internal class LambentHookShader private constructor(
    val name: String,
    private val passes: List<Pass>,
    private val textures: Map<String, Int>,
) {
    private class Pass(
        val program: Int,
        val binds: List<String>,
        val save: String?,
        val scale: Int,
        val components: Int,
    )

    private val saved = HashMap<String, Target>()

    private class Target(val texture: Int, val fbo: Int, val width: Int, val height: Int)

    /** Runs the passes on [picture] (Y' in alpha, [width] x [height]); returns the texture holding the result's Y' (red). */
    fun run(picture: Int, width: Int, height: Int, quad: java.nio.FloatBuffer): Pair<Int, Int> {
        var last = picture to 1
        for ((index, pass) in passes.withIndex()) {
            val w = width * pass.scale
            val h = height * pass.scale
            val key = pass.save ?: "pass$index"
            val target = saved[key]?.takeIf { it.width == w && it.height == h } ?: makeTarget(w, h, pass.components).also {
                saved[key]?.let { old -> release(old) }
                saved[key] = it
            }
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, target.fbo)
            GLES30.glViewport(0, 0, w, h)
            GLES30.glUseProgram(pass.program)
            var unit = 0
            for (bind in pass.binds) {
                val texture = when (bind) {
                    "HOOKED" -> picture
                    else -> textures[bind] ?: saved[bind]?.texture ?: continue
                }
                GLES30.glActiveTexture(GLES30.GL_TEXTURE0 + unit)
                GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, texture)
                GLES30.glUniform1i(GLES30.glGetUniformLocation(pass.program, "${bind}_raw"), unit)
                val size = when (bind) {
                    "HOOKED" -> floatArrayOf(width.toFloat(), height.toFloat())
                    else -> saved[bind]?.let { floatArrayOf(it.width.toFloat(), it.height.toFloat()) }
                }
                if (size != null) GLES30.glUniform2f(GLES30.glGetUniformLocation(pass.program, "${bind}_size"), size[0], size[1])
                unit++
            }
            val pos = GLES30.glGetAttribLocation(pass.program, "pos")
            GLES30.glEnableVertexAttribArray(pos)
            GLES30.glVertexAttribPointer(pos, 2, GLES30.GL_FLOAT, false, 0, quad)
            GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4)
            last = target.texture to pass.scale
        }
        return last
    }

    fun release() {
        saved.values.forEach { release(it) }
        saved.clear()
        passes.forEach { GLES30.glDeleteProgram(it.program) }
        GLES30.glDeleteTextures(textures.size, textures.values.toIntArray(), 0)
    }

    private fun release(target: Target) {
        GLES30.glDeleteFramebuffers(1, intArrayOf(target.fbo), 0)
        GLES30.glDeleteTextures(1, intArrayOf(target.texture), 0)
    }

    private fun makeTarget(w: Int, h: Int, components: Int): Target {
        val t = IntArray(1)
        GLES30.glGenTextures(1, t, 0)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, t[0])
        GLES30.glTexStorage2D(GLES30.GL_TEXTURE_2D, 1, if (components == 1) GLES30.GL_R16F else GLES30.GL_RGBA16F, w, h)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
        val f = IntArray(1)
        GLES30.glGenFramebuffers(1, f, 0)
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, f[0])
        GLES30.glFramebufferTexture2D(GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0, GLES30.GL_TEXTURE_2D, t[0], 0)
        return Target(t[0], f[0], w, h)
    }

    companion object {
        private const val TAG = "LambentHdr"

        /** Parses and compiles [source] (the .hook file's text); null, with the reason logged, when it can't be used. */
        fun load(name: String, source: String): LambentHookShader? {
            val blocks = Regex("""(?m)^//!(DESC|TEXTURE)\b""").let { re ->
                val starts = re.findAll(source).map { it.range.first }.toList()
                starts.mapIndexed { i, s -> source.substring(s, if (i + 1 < starts.size) starts[i + 1] else source.length) }
            }
            val textures = HashMap<String, Int>()
            val passes = ArrayList<Pass>()
            // The shader's own textures come after the passes in the file: make them first, so the passes know their names.
            for (block in blocks.sortedBy { if (it.startsWith("//!TEXTURE")) 0 else 1 }) {
                val lines = block.lines()
                val dirs = HashMap<String, MutableList<String>>()
                var bodyStart = 0
                for ((i, line) in lines.withIndex()) {
                    if (!line.startsWith("//!")) { bodyStart = i; break }
                    val parts = line.removePrefix("//!").trim().split(Regex("\\s+"), limit = 2)
                    dirs.getOrPut(parts[0]) { ArrayList() }.add(parts.getOrElse(1) { "" })
                    bodyStart = i + 1
                }
                val body = lines.drop(bodyStart).joinToString("\n")
                if (dirs.containsKey("TEXTURE")) {
                    val texName = dirs["TEXTURE"]!!.first()
                    val (w, h) = dirs["SIZE"]!!.first().split(" ").map { it.toInt() }
                    val hex = body.filter { !it.isWhitespace() }
                    val bytes = ByteArray(hex.length / 2) { ((Character.digit(hex[it * 2], 16) shl 4) or Character.digit(hex[it * 2 + 1], 16)).toByte() }
                    val buffer = ByteBuffer.allocateDirect(bytes.size).order(ByteOrder.nativeOrder()).put(bytes).also { it.position(0) }
                    val type = when (bytes.size) {
                        w * h * 16 -> GLES30.GL_FLOAT
                        w * h * 8 -> GLES30.GL_HALF_FLOAT
                        else -> { Log.e(TAG, "$name: texture $texName has ${bytes.size} bytes for ${w}x$h"); return null }
                    }
                    val t = IntArray(1)
                    GLES30.glGenTextures(1, t, 0)
                    GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, t[0])
                    GLES30.glTexImage2D(GLES30.GL_TEXTURE_2D, 0, GLES30.GL_RGBA16F, w, h, 0, GLES30.GL_RGBA, type, buffer)
                    val filter = if (dirs["FILTER"]?.first()?.uppercase() == "NEAREST") GLES30.GL_NEAREST else GLES30.GL_LINEAR
                    GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, filter)
                    GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, filter)
                    GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
                    GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
                    textures[texName] = t[0]
                    continue
                }
                if (dirs["HOOK"]?.firstOrNull() != "LUMA") { Log.e(TAG, "$name: only LUMA hooks are supported"); return null }
                val binds = dirs["BIND"].orEmpty()
                val scale = dirs["WIDTH"]?.first()?.let { Regex("""^(\d+)\s+HOOKED\.w\s+\*$""").find(it.trim())?.groupValues?.get(1)?.toInt() } ?: 1
                val components = dirs["COMPONENTS"]?.first()?.toIntOrNull() ?: 4
                val program = compile(name, binds, textures.keys, body) ?: return null
                passes += Pass(program, binds, dirs["SAVE"]?.first(), scale, components)
            }
            if (passes.isEmpty()) return null
            // A SAVE'd texture is the size of its own pass: a later pass's `<NAME>_size` reads it from there.
            return LambentHookShader(name, passes, textures)
        }

        private fun compile(name: String, binds: List<String>, ownTextures: Set<String>, body: String): Int? {
            val head = StringBuilder("#version 300 es\nprecision highp float;\nprecision highp int;\nin vec2 hook_pos;\nout vec4 hook_out;\n")
            for (b in binds) {
                head.append("uniform highp sampler2D ${b}_raw;\n")
                if (b in ownTextures) {
                    head.append("#define $b ${b}_raw\n")
                    continue
                }
                head.append("uniform vec2 ${b}_size;\n#define ${b}_pt (1.0 / ${b}_size)\n#define ${b}_pos hook_pos\n")
                // HOOKED is the stage's picture, Y' in alpha: a LUMA hook reads it in .x.
                val read = if (b == "HOOKED") "vec4(texture(${b}_raw, p).a)" else "texture(${b}_raw, p)"
                head.append("vec4 ${b}_tex(vec2 p) { return $read; }\n")
                head.append("#define ${b}_texOff(o) ${b}_tex(${b}_pos + ${b}_pt * vec2(o))\n")
            }
            val fs = "$head\n$body\nvoid main() { hook_out = hook(); }\n"
            val vs = "#version 300 es\nin vec2 pos; out vec2 hook_pos;\nvoid main() { hook_pos = pos * 0.5 + 0.5; gl_Position = vec4(pos, 0.0, 1.0); }\n"
            val p = GLES30.glCreateProgram()
            for ((type, src) in listOf(GLES30.GL_VERTEX_SHADER to vs, GLES30.GL_FRAGMENT_SHADER to fs)) {
                val s = GLES30.glCreateShader(type)
                GLES30.glShaderSource(s, src)
                GLES30.glCompileShader(s)
                val ok = IntArray(1)
                GLES30.glGetShaderiv(s, GLES30.GL_COMPILE_STATUS, ok, 0)
                if (ok[0] == 0) {
                    Log.e(TAG, "$name: ${GLES30.glGetShaderInfoLog(s)}")
                    return null
                }
                GLES30.glAttachShader(p, s)
            }
            GLES30.glLinkProgram(p)
            val linked = IntArray(1)
            GLES30.glGetProgramiv(p, GLES30.GL_LINK_STATUS, linked, 0)
            if (linked[0] == 0) {
                Log.e(TAG, "$name: ${GLES30.glGetProgramInfoLog(p)}")
                return null
            }
            return p
        }
    }
}
