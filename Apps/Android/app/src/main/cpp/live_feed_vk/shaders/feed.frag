#version 450
layout(location = 0) in vec2 vUv;
layout(location = 0) out vec4 outColor;
layout(set = 0, binding = 0) uniform sampler2D uFeed;
layout(set = 0, binding = 1) uniform sampler2D uLut;
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
    float aspectFill; // unused placeholder pad
} u;

const vec3 LUMA709 = vec3(0.2126, 0.7152, 0.0722);
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
    // Packed cube: width = n*n, height = n
    vec2 lo = vec2((s0 * n + x) / (n * n), y / n);
    vec2 hi = vec2((s1 * n + x) / (n * n), y / n);
    return mix(texture(uLut, lo).rgb, texture(uLut, hi).rgb, b - s0);
}

void main() {
    // Flip Y: Android bitmap row0 is top; Vulkan uv y=0 bottom for this path
    vec2 uv = vec2(vUv.x, 1.0 - vUv.y);
    vec3 source = texture(uFeed, uv).rgb;
    vec3 color = grade(source);
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
