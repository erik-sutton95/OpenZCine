#version 100

precision highp float;

uniform sampler2D uTexSampler;
uniform sampler2D uLut;
uniform sampler2D uLimitsPaintCube;
uniform sampler2D uLimitsWeightCube;
uniform float uFlipInputY;
uniform float uLutSize;
uniform float uLimitsPaintSize;
uniform float uLimitsWeightSize;
uniform float uLimitsOn;
uniform vec2 uSourceSize;
uniform vec2 uDisplaySize;

uniform float uPeakingOn;
uniform vec3 uPeakingColor;
uniform float uPeakingRatioThreshold;
uniform float uPeakingNoiseGate;

uniform float uZebraHighlightOn;
uniform float uZebraHighlight;
uniform vec3 uZebraHighlightColor;
uniform float uZebraMidtoneOn;
uniform float uZebraMidtone;
uniform vec3 uZebraMidtoneColor;

varying vec2 vTexSamplingCoord;

const vec3 LUMA_709 = vec3(0.2126, 0.7152, 0.0722);
const float ATLAS_COLUMNS = 8.0;
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

vec2 atlasCoordinate(float slice, vec2 redGreen, float cubeSize) {
    float tileX = mod(slice, ATLAS_COLUMNS);
    float tileY = floor(slice / ATLAS_COLUMNS);
    vec2 pixel = vec2(
        tileX * cubeSize + clamp(redGreen.x, 0.0, 1.0) * (cubeSize - 1.0) + 0.5,
        tileY * cubeSize + clamp(redGreen.y, 0.0, 1.0) * (cubeSize - 1.0) + 0.5
    );
    // GLUtils uploads Android bitmap row zero at v=0 for sampler coordinates.
    // Flipping here would address an unused atlas row instead of the selected
    // green row, which collapses the upper green axis to black on hardware.
    return pixel / (cubeSize * ATLAS_COLUMNS);
}

vec3 sampleLut(float cubeSize, vec3 color) {
    float blue = clamp(color.b, 0.0, 1.0) * (cubeSize - 1.0);
    float lowerSlice = floor(blue);
    float upperSlice = min(lowerSlice + 1.0, cubeSize - 1.0);
    vec3 lower = texture2D(
        uLut,
        atlasCoordinate(lowerSlice, color.rg, cubeSize)
    ).rgb;
    vec3 upper = texture2D(
        uLut,
        atlasCoordinate(upperSlice, color.rg, cubeSize)
    ).rgb;
    return mix(lower, upper, blue - lowerSlice);
}

vec3 grade(vec3 color) {
    if (uLutSize < 2.0) {
        return color;
    }
    return sampleLut(uLutSize, color);
}

vec3 sampleSource(vec2 coordinate) {
    float y = mix(coordinate.y, 1.0 - coordinate.y, uFlipInputY);
    return texture2D(uTexSampler, vec2(coordinate.x, y)).rgb;
}

vec3 limitsPaint(vec3 color) {
    if (uLimitsPaintSize < 2.0) {
        return color;
    }
    float blue = clamp(color.b, 0.0, 1.0) * (uLimitsPaintSize - 1.0);
    float lowerSlice = floor(blue);
    float upperSlice = min(lowerSlice + 1.0, uLimitsPaintSize - 1.0);
    vec3 lower = texture2D(
        uLimitsPaintCube,
        atlasCoordinate(lowerSlice, color.rg, uLimitsPaintSize)
    ).rgb;
    vec3 upper = texture2D(
        uLimitsPaintCube,
        atlasCoordinate(upperSlice, color.rg, uLimitsPaintSize)
    ).rgb;
    return mix(lower, upper, blue - lowerSlice);
}

float limitsWeight(vec3 color) {
    if (uLimitsWeightSize < 2.0) {
        return 0.0;
    }
    float blue = clamp(color.b, 0.0, 1.0) * (uLimitsWeightSize - 1.0);
    float lowerSlice = floor(blue);
    float upperSlice = min(lowerSlice + 1.0, uLimitsWeightSize - 1.0);
    float lower = texture2D(
        uLimitsWeightCube,
        atlasCoordinate(lowerSlice, color.rg, uLimitsWeightSize)
    ).r;
    float upper = texture2D(
        uLimitsWeightCube,
        atlasCoordinate(upperSlice, color.rg, uLimitsWeightSize)
    ).r;
    return clamp(mix(lower, upper, blue - lowerSlice), 0.0, 1.0);
}

// Focus peaking measures BLUR RADIUS, not edge contrast.
//
// A gradient magnitude scales with amplitude as much as with focus, so a bright
// defocused highlight rim outranks genuinely sharp low-contrast detail — the
// overlay then paints background bokeh and skips the subject. Running the operator
// on the source and again on a re-blurred copy, then dividing, cancels amplitude
// exactly and leaves a number that depends only on how blurred the edge is:
// PEAKING_RATIO_CEILING when perfectly sharp, falling to 1.0 when fully defocused.
//
// Every constant below comes from `Peaking` in shared core, which is where the
// derivation, the calibration tables and the measurements live. `Peaking.overlay`
// is the reference this is transcribed from, and `RunnerTests` checks that
// reference against the live iOS Core Image graph pixel-for-pixel — so the chain
// from this shader to what an iPhone renders is closed.
//
// Measured on the RAW source: the ratio is near-invariant to the camera's
// transfer curve, and the contrast stretch that used to run here clamped
// everything above ~75% code value flat, making in-focus highlight detail
// undetectable however sharp it was.
//
// ONE DIFFERENCE FROM iOS: no morphological closing.
//
// iOS closes the finished stroke (`Peaking.maskClosingRadius`), which rejoins the
// dashes a strict noise gate punches into edges that ARE sharp; measured, it takes
// fragmentation from 18.9% to 1.6% at equal ink. It cannot be folded into this
// pass. `Peaking.closingOffsets` is a five-point plus, so dilate-then-erode spans
// a 13-point diamond, and each of those 13 points needs its own re-blur
// neighbourhood — about 130 live floats of intermediate state, against the ~25
// this shader uses now. That is a pass boundary in any renderer, which is why iOS
// spends two stock filters on it. Closing therefore wants an offscreen mask pass
// here too, tracked separately; without it Android reads slightly grainier than
// iOS at the same setting, and everything else about the two matches.
float sourceGrey(vec2 coordinate) {
    vec3 color = sampleSource(coordinate);
    return (color.r + color.g + color.b) / 3.0;
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
    vec3 source = sampleSource(vTexSamplingCoord);
    vec3 color = grade(source);

    if (uLimitsOn > 0.5) {
        color = mix(color, limitsPaint(source), limitsWeight(source));
    }

    if (uPeakingOn > 0.5) {
        vec2 sourceSize = max(uSourceSize, vec2(1.0));
        vec2 inset = vec2(PEAKING_EDGE_INSET) / sourceSize;
        if (
            vTexSamplingCoord.x >= inset.x
            && vTexSamplingCoord.y >= inset.y
            && vTexSamplingCoord.x < 1.0 - inset.x
            && vTexSamplingCoord.y < 1.0 - inset.y
        ) {
            // Snap to the source pixel grid before measuring anything.
            //
            // The operator is defined on source pixels — one texel per tap, and no spacing
            // normalisation, because `CIEdges` and the re-blur radius are both fixed at one
            // pixel. This shader, though, runs once per DISPLAY pixel. Measuring from a
            // fractional source position would make every tap a bilinear blend of four source
            // pixels, which pre-filters away the very high frequencies the detector exists to
            // find, and would let neighbouring display fragments inside one source pixel
            // disagree — a mottled overlay. Snapping costs one floor() and yields the same mask
            // an iPhone computes at source resolution.
            vec2 texel = 1.0 / sourceSize;
            vec2 centre = (floor(vTexSamplingCoord * sourceSize) + 0.5) * texel;

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
                (uPeakingNoiseGate == 0.0 ? 0.0
                    : (coarse - uPeakingNoiseGate * PEAKING_GATE_FLOOR)
                        / (uPeakingNoiseGate * (1.0 - PEAKING_GATE_FLOOR))),
                0.0,
                1.0);
            // LINEAR ramps, deliberately not smoothstep: Core Image reaches these with a
            // scale-and-clamp pair, and on a ramp this narrow the Hermite curve is a visible
            // difference in stroke weight rather than a rounding one.
            float stroke = clamp((ratio - uPeakingRatioThreshold) / PEAKING_AA, 0.0, 1.0) * gate;
            float under = clamp(
                (ratio - (uPeakingRatioThreshold - PEAKING_AA * PEAKING_UNDER_OFFSET)) / PEAKING_AA,
                0.0,
                1.0) * gate;
            // Hairline first at its full ramp opacity, then the stroke over the top of it —
            // `ImageEffectsCompositor.composite`'s two blends, in that order. The hairline is what
            // stops a bright stroke from vanishing into a bright subject.
            color = mix(color, PEAKING_UNDER_COLOR, under);
            color = mix(color, uPeakingColor, stroke);
        }
    }

    if (uZebraHighlightOn > 0.5 || uZebraMidtoneOn > 0.5) {
        float luma = dot(source, LUMA_709);
        // Match Android/Skia's top-down display coordinates even though GL fragments count up.
        vec2 displayCoordinate = vec2(
            vTexSamplingCoord.x * uDisplaySize.x,
            (1.0 - vTexSamplingCoord.y) * uDisplaySize.y
        );
        float stripe = step(
            0.5,
            fract((displayCoordinate.x + displayCoordinate.y) / STRIPE_PITCH)
        );
        if (uZebraHighlightOn > 0.5) {
            float highlightMask = clamp(
                (luma - uZebraHighlight) * ZEBRA_GAIN,
                0.0,
                1.0
            );
            color = mix(color, uZebraHighlightColor, highlightMask * stripe);
        }
        if (uZebraMidtoneOn > 0.5) {
            float midtoneMask =
                clamp(
                    (luma - (uZebraMidtone - ZEBRA_HALF_WIDTH)) * ZEBRA_GAIN,
                    0.0,
                    1.0
                )
                * clamp(
                    ((uZebraMidtone + ZEBRA_HALF_WIDTH) - luma) * ZEBRA_GAIN,
                    0.0,
                    1.0
                );
            color = mix(color, uZebraMidtoneColor, midtoneMask * stripe);
        }
    }

    gl_FragColor = vec4(color, 1.0);
}
