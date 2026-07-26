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
const float PEAKING_EDGE_INSET = 6.0;
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
// overlay then paints background bokeh and skips the subject. Taking the gradient
// at two spacings and dividing cancels amplitude exactly, leaving a number that
// depends only on how blurred the edge is: 2.0 when perfectly sharp, falling to
// 1.0 when fully defocused. See `Peaking` in shared core for the derivation and
// the thresholds.
//
// Measured on the RAW source: the ratio is near-invariant to the camera's
// transfer curve, and the contrast stretch that used to run here clamped
// everything above ~75% code value flat, making in-focus highlight detail
// undetectable however sharp it was.
float sourceGrey(vec2 coordinate) {
    vec3 color = sampleSource(coordinate);
    return (color.r + color.g + color.b) / 3.0;
}

// Central-difference magnitude over a horizontal and a vertical pair, normalised
// to a per-pixel slope so the two scales are directly comparable.
float gradientAt(vec2 coordinate, vec2 spacing, float taps) {
    float l = sourceGrey(coordinate - vec2(spacing.x, 0.0));
    float r = sourceGrey(coordinate + vec2(spacing.x, 0.0));
    float u = sourceGrey(coordinate - vec2(0.0, spacing.y));
    float d = sourceGrey(coordinate + vec2(0.0, spacing.y));
    return length(vec2(r - l, d - u)) * 0.5 / taps;
}

void main() {
    vec3 source = sampleSource(vTexSamplingCoord);
    vec3 color = grade(source);

    if (uLimitsOn > 0.5) {
        color = mix(color, limitsPaint(source), limitsWeight(source));
    }

    if (uPeakingOn > 0.5) {
        vec2 inset = vec2(PEAKING_EDGE_INSET) / max(uSourceSize, vec2(1.0));
        if (
            vTexSamplingCoord.x >= inset.x
            && vTexSamplingCoord.y >= inset.y
            && vTexSamplingCoord.x < 1.0 - inset.x
            && vTexSamplingCoord.y < 1.0 - inset.y
        ) {
            // Tap spacing tracks resolution so the same optical blur reads the same on a
            // downscaled live feed and on a 4K clip.
            float scale = max(1.0, max(uSourceSize.x, uSourceSize.y) / 1000.0);
            vec2 fineStep = scale / max(uSourceSize, vec2(1.0));
            float fine = gradientAt(vTexSamplingCoord, fineStep, 1.0);
            float coarse = gradientAt(vTexSamplingCoord, fineStep * 2.0, 2.0);
            float ratio = fine / max(coarse, 1e-4);
            // Noise is not lens-blurred, so it always reads as perfectly sharp; the ratio
            // cannot reject it and this gate is what keeps shadows from sparkling.
            float gate = smoothstep(uPeakingNoiseGate * 0.7, uPeakingNoiseGate, coarse);
            // Very narrow AA — peaking reads as a drawn line, not a glow.
            float aa = 0.06;
            float core = smoothstep(uPeakingRatioThreshold, uPeakingRatioThreshold + aa, ratio)
                * gate;
            float under = smoothstep(
                uPeakingRatioThreshold - aa * 0.35, uPeakingRatioThreshold, ratio
            ) * gate * (1.0 - core);
            color = mix(color, vec3(0.04, 0.04, 0.05), under * 0.28);
            color = mix(color, uPeakingColor, core);
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
