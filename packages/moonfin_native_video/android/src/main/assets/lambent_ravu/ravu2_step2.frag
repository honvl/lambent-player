#version 320 es
precision highp float;
precision highp sampler2D;
in vec2 v;
out vec4 fragColor;
uniform sampler2D HOOKED;
uniform vec2 HOOKED_size;
uniform vec2 HOOKED_pt;
#define HOOKED_pos v
#define HOOKED_texOff(o) texture(HOOKED, v + HOOKED_pt * (o))
uniform sampler2D ravu_lite_int;
#define ravu_lite_int_texOff(o) texture(ravu_lite_int, v + HOOKED_pt * (o))
vec4 hook() {
    vec2 dir = fract(HOOKED_pos * HOOKED_size) - 0.5;
    int idx = int(dir.x > 0.0) * 2 + int(dir.y > 0.0);
    return vec4(ravu_lite_int_texOff(-dir)[idx], 0.0, 0.0, 0.0);
}

void main() { fragColor = hook(); }
