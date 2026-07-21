#version 450
layout(location = 0) in vec2 vUv;
layout(location = 0) out vec4 outColor;
layout(set = 0, binding = 0) uniform sampler2D uFeed;
layout(set = 0, binding = 1) uniform sampler2D uLut;
// std140 layout must match GpuParams in live_feed_vk_renderer.cpp.
layout(set = 0, binding = 2) uniform Params {
    float lutSize;
    float peakingOn;
    float zebraHighlightOn;
    float zebraMidtoneOn;
    vec4 peakingColor;
    vec4 zebraHighlightColor;
    vec4 zebraMidtoneColor;
    float peakingThreshold;
    float peakingRamp;
    float zebraHighlight;
    float zebraMidtone;
    float aspectFill;
    vec4 deLogCurve0to3;
    float deLogCurve4;
    vec2 sourceSize;
    float pad;
} u;

const vec3 LUMA709 = vec3(0.2126, 0.7152, 0.0722);
const float PEAKING_EDGE_INSET = 6.0;
const float ZEBRA_GAIN = 40.0;
const float ZEBRA_HALF_WIDTH = 5.0 / 255.0;
const float STRIPE_PITCH = 14.14;

vec3 grade(vec3 c) {
    if (u.lutSize < 2.0) return c;
    float n = u.lutSize;
    float b = clamp(c.b, 0.0, 1.0) * (n - 1.0);
    float s0 = floor(b);
    float s1 = min(s0 + 1.0, n - 1.0);
    float x = clamp(c.r, 0.0, 1.0) * (n - 1.0) + 0.5;
    float y = clamp(c.g, 0.0, 1.0) * (n - 1.0) + 0.5;
    vec2 lo = vec2((s0 * n + x) / (n * n), y / n);
    vec2 hi = vec2((s1 * n + x) / (n * n), y / n);
    return mix(texture(uLut, lo).rgb, texture(uLut, hi).rgb, b - s0);
}

float monotoneTone(float y0, float y1, float y2, float y3, float t) {
    float m1 = 0.5 * (y2 - y0);
    float m2 = 0.5 * (y3 - y1);
    float t2 = t * t;
    float t3 = t2 * t;
    float value =
        (2.0 * t3 - 3.0 * t2 + 1.0) * y1
        + (t3 - 2.0 * t2 + t) * m1
        + (-2.0 * t3 + 3.0 * t2) * y2
        + (t3 - t2) * m2;
    return clamp(value, min(y1, y2), max(y1, y2));
}

float deLogGrey(vec2 uv) {
    vec3 c = texture(uFeed, uv).rgb;
    float position = clamp((c.r + c.g + c.b) / 3.0, 0.0, 1.0) * 4.0;
    float segment = min(floor(position), 3.0);
    float fraction = position - segment;
    if (segment < 0.5) {
        return monotoneTone(
            u.deLogCurve0to3.x, u.deLogCurve0to3.x, u.deLogCurve0to3.y, u.deLogCurve0to3.z, fraction);
    }
    if (segment < 1.5) {
        return monotoneTone(
            u.deLogCurve0to3.x, u.deLogCurve0to3.y, u.deLogCurve0to3.z, u.deLogCurve0to3.w, fraction);
    }
    if (segment < 2.5) {
        return monotoneTone(
            u.deLogCurve0to3.y, u.deLogCurve0to3.z, u.deLogCurve0to3.w, u.deLogCurve4, fraction);
    }
    return monotoneTone(
        u.deLogCurve0to3.z, u.deLogCurve0to3.w, u.deLogCurve4, u.deLogCurve4, fraction);
}

// 1 px central differences — no Sobel / pre-blur fattening.
float edgeMagnitude(vec2 uv) {
    vec2 px = 1.0 / max(u.sourceSize, vec2(1.0));
    float left = deLogGrey(uv - vec2(px.x, 0.0));
    float right = deLogGrey(uv + vec2(px.x, 0.0));
    float up = deLogGrey(uv - vec2(0.0, px.y));
    float down = deLogGrey(uv + vec2(0.0, px.y));
    return length(vec2(right - left, down - up)) * 0.5;
}

void main() {
    vec2 uv = vec2(vUv.x, 1.0 - vUv.y);
    vec3 source = texture(uFeed, uv).rgb;
    vec3 color = grade(source);

    if (u.peakingOn > 0.5) {
        vec2 srcPx = uv * max(u.sourceSize, vec2(1.0));
        if (srcPx.x >= PEAKING_EDGE_INSET && srcPx.y >= PEAKING_EDGE_INSET
            && srcPx.x < u.sourceSize.x - PEAKING_EDGE_INSET
            && srcPx.y < u.sourceSize.y - PEAKING_EDGE_INSET) {
            float g = edgeMagnitude(uv);
            float thr = clamp(u.peakingThreshold * 30.0, 0.045, 0.14);
            float aa = thr * (0.06 + 0.04 * clamp(160.0 / max(u.peakingRamp, 1.0), 0.5, 1.5));
            float core = smoothstep(thr, thr + aa, g);
            float under = smoothstep(thr - aa * 0.35, thr, g) * (1.0 - core);
            color = mix(color, vec3(0.04, 0.04, 0.05), under * 0.28);
            color = mix(color, u.peakingColor.rgb, core);
        }
    }

    if (u.zebraHighlightOn > 0.5 || u.zebraMidtoneOn > 0.5) {
        float luma = dot(source, LUMA709);
        float stripe = step(0.5, fract((gl_FragCoord.x + gl_FragCoord.y) / STRIPE_PITCH));
        if (u.zebraHighlightOn > 0.5) {
            float hi = clamp((luma - u.zebraHighlight) * ZEBRA_GAIN, 0.0, 1.0);
            color = mix(color, u.zebraHighlightColor.rgb, hi * stripe);
        }
        if (u.zebraMidtoneOn > 0.5) {
            float mid = clamp((luma - (u.zebraMidtone - ZEBRA_HALF_WIDTH)) * ZEBRA_GAIN, 0.0, 1.0)
                * clamp(((u.zebraMidtone + ZEBRA_HALF_WIDTH) - luma) * ZEBRA_GAIN, 0.0, 1.0);
            color = mix(color, u.zebraMidtoneColor.rgb, mid * stripe);
        }
    }
    outColor = vec4(color, 1.0);
}
