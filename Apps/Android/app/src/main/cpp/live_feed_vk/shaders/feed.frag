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
    float peakingRatioThreshold;
    float peakingNoiseGate;
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

// Focus peaking measures BLUR RADIUS, not edge contrast: the gradient at two
// spacings, divided, cancels edge amplitude and leaves only how defocused the edge
// is (2.0 sharp -> 1.0 fully blurred). Measured on the RAW source. See `Peaking` in
// shared core. The de-log members of the uniform block are no longer read here; they
// are kept so the std140 layout matches GpuParams unchanged.
float sourceGrey(vec2 uv) {
    vec3 c = texture(uFeed, uv).rgb;
    return (c.r + c.g + c.b) / 3.0;
}

float gradientAt(vec2 uv, vec2 spacing, float taps) {
    float left = sourceGrey(uv - vec2(spacing.x, 0.0));
    float right = sourceGrey(uv + vec2(spacing.x, 0.0));
    float up = sourceGrey(uv - vec2(0.0, spacing.y));
    float down = sourceGrey(uv + vec2(0.0, spacing.y));
    return length(vec2(right - left, down - up)) * 0.5 / taps;
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
            float scale = max(1.0, max(u.sourceSize.x, u.sourceSize.y) / 1000.0);
            vec2 fineStep = scale / max(u.sourceSize, vec2(1.0));
            float fine = gradientAt(uv, fineStep, 1.0);
            float coarse = gradientAt(uv, fineStep * 2.0, 2.0);
            float ratio = fine / max(coarse, 1e-4);
            // Noise is not lens-blurred, so it always reads as sharp; the gate rejects it.
            float gate = smoothstep(u.peakingNoiseGate * 0.7, u.peakingNoiseGate, coarse);
            float aa = 0.06;
            float core =
                smoothstep(u.peakingRatioThreshold, u.peakingRatioThreshold + aa, ratio) * gate;
            float under = smoothstep(
                u.peakingRatioThreshold - aa * 0.35, u.peakingRatioThreshold, ratio
            ) * gate * (1.0 - core);
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
