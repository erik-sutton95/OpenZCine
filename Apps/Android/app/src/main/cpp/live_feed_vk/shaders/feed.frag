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
// Focus peaking, all from `Peaking` in shared core — see the block comment below.
const float PEAKING_EDGE_INSET = 6.0;
const float PEAKING_W0 = 0.382992;
const float PEAKING_W1 = 0.241798;
const float PEAKING_W2 = 0.060662;
const float PEAKING_W3 = 0.006044;
const float PEAKING_RATIO_CEILING = 4.0;
const float PEAKING_AA = 0.12;
const float PEAKING_UNDER_OFFSET = 0.5;
const float PEAKING_GATE_FLOOR = 0.7;
const vec3 PEAKING_UNDER_COLOR = vec3(0.04, 0.04, 0.05);
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

// Focus peaking measures BLUR RADIUS, not edge contrast: the operator run on the
// source and again on a re-blurred copy, then divided, cancels edge amplitude and
// leaves only how defocused the edge is (PEAKING_RATIO_CEILING sharp -> 1.0 fully
// blurred). Measured on the RAW source.
//
// Every constant comes from `Peaking` in shared core, which holds the derivation,
// the calibration tables and the measurements. `Peaking.overlay` is the reference
// this is transcribed from, and `RunnerTests` checks that reference against the
// live iOS Core Image graph pixel-for-pixel — so the chain from this shader to what
// an iPhone renders is closed.
//
// ONE DIFFERENCE FROM iOS: no morphological closing. `Peaking.closingOffsets` is a
// five-point plus, so dilate-then-erode spans a 13-point diamond and each of those
// points needs its own re-blur neighbourhood — roughly 130 live floats against the
// ~25 used here, which is a pass boundary in any renderer. It wants an offscreen
// mask pass, tracked separately; without it Android reads slightly grainier than
// iOS at the same setting, and everything else matches.
//
// The de-log members of the uniform block are no longer read here; they are kept so
// the std140 layout matches GpuParams unchanged.
float sourceGrey(vec2 uv) {
    vec3 c = texture(uFeed, uv).rgb;
    return (c.r + c.g + c.b) / 3.0;
}

// Weight of a tap `offset` pixels from the centre of the separable re-blur, zero
// beyond its reach. A function rather than an indexed array so the kernel needs no
// local array at all — GLSL ES 2.0, SkSL and GLSL 4.5 all inline this identically.
float peakingTapWeight(float offset) {
    float d = abs(offset);
    return d < 0.5 ? PEAKING_W0
        : d < 1.5 ? PEAKING_W1
        : d < 2.5 ? PEAKING_W2
        : d < 3.5 ? PEAKING_W3
        : 0.0;
}

// The operator: a squared Roberts cross over the 2x2 quad anchored at the pixel,
// reproducing `CIEdges`. SQUARED — a 0.2 step gives 0.08, a 0.4 step 0.32 — which is
// the domain every threshold in `Peaking` lives in.
float peakingRoberts(float a, float b, float c, float d) {
    float d1 = d - a;
    float d2 = c - b;
    return d1 * d1 + d2 * d2;
}

void main() {
    vec2 uv = vec2(vUv.x, 1.0 - vUv.y);
    vec3 source = texture(uFeed, uv).rgb;
    vec3 color = grade(source);

    if (u.peakingOn > 0.5) {
        vec2 sourceSize = max(u.sourceSize, vec2(1.0));
        vec2 srcPx = uv * sourceSize;
        if (srcPx.x >= PEAKING_EDGE_INSET && srcPx.y >= PEAKING_EDGE_INSET
            && srcPx.x < sourceSize.x - PEAKING_EDGE_INSET
            && srcPx.y < sourceSize.y - PEAKING_EDGE_INSET) {
            // Snap to the source pixel grid before measuring anything. The operator is defined
            // on source pixels (one texel per tap, no spacing normalisation — `CIEdges` and the
            // re-blur radius are both fixed at one pixel), but this shader runs once per DISPLAY
            // pixel. Measuring from a fractional source position would make every tap a bilinear
            // blend of four source pixels, pre-filtering away the high frequencies the detector
            // exists to find and letting fragments inside one source pixel disagree.
            vec2 texel = 1.0 / sourceSize;
            vec2 centre = (floor(srcPx) + 0.5) * texel;

            // Separable re-blur and the operator's two quads over ONE shared 8x8 source
            // neighbourhood. `vp0`/`vp1` are the vertical halves at the quad's two rows, and the
            // four `b**` accumulate the horizontal half straight into the re-blurred values the
            // coarse operator needs — so the whole kernel holds a handful of floats and needs no
            // local array. 68 source taps in total.
            float b00 = 0.0;
            float b10 = 0.0;
            float b01 = 0.0;
            float b11 = 0.0;
            for (int col = 0; col < 8; col++) {
                float dx = float(col) - 3.0;
                float vp0 = 0.0;
                float vp1 = 0.0;
                for (int row = 0; row < 8; row++) {
                    float dy = float(row) - 3.0;
                    float g = sourceGrey(centre + vec2(dx, dy) * texel);
                    vp0 += peakingTapWeight(dy) * g;
                    vp1 += peakingTapWeight(dy - 1.0) * g;
                }
                float wx0 = peakingTapWeight(dx);
                float wx1 = peakingTapWeight(dx - 1.0);
                b00 += wx0 * vp0;
                b10 += wx1 * vp0;
                b01 += wx0 * vp1;
                b11 += wx1 * vp1;
            }
            float coarse = peakingRoberts(b00, b10, b01, b11);
            float fine = peakingRoberts(
                sourceGrey(centre),
                sourceGrey(centre + vec2(1.0, 0.0) * texel),
                sourceGrey(centre + vec2(0.0, 1.0) * texel),
                sourceGrey(centre + vec2(1.0, 1.0) * texel));
            float ratio = min(fine / max(coarse, 1e-9), PEAKING_RATIO_CEILING);
            // Noise is not lens-blurred, so it always reads as perfectly sharp; the ratio cannot
            // reject it and this gate is what keeps shadows from sparkling. It arrives already
            // scaled for the feed's encoding, so there is no mode policy here.
            float gate = clamp(
                (coarse - u.peakingNoiseGate * PEAKING_GATE_FLOOR)
                    / max(u.peakingNoiseGate * (1.0 - PEAKING_GATE_FLOOR), 1e-9),
                0.0,
                1.0);
            // LINEAR ramps, deliberately not smoothstep: Core Image reaches these with a
            // scale-and-clamp pair, and on a ramp this narrow the Hermite curve is a visible
            // difference in stroke weight rather than a rounding one.
            float stroke = clamp((ratio - u.peakingRatioThreshold) / PEAKING_AA, 0.0, 1.0) * gate;
            float under = clamp(
                (ratio - (u.peakingRatioThreshold - PEAKING_AA * PEAKING_UNDER_OFFSET)) / PEAKING_AA,
                0.0,
                1.0) * gate;
            // Hairline first at its full ramp opacity, then the stroke over the top of it —
            // `ImageEffectsCompositor.composite`'s two blends, in that order. The hairline is what
            // stops a bright stroke from vanishing into a bright subject.
            color = mix(color, PEAKING_UNDER_COLOR, under);
            color = mix(color, u.peakingColor.rgb, stroke);
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
