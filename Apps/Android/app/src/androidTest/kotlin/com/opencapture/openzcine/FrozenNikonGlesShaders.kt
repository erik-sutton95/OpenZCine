package com.opencapture.openzcine

// Exact bytes of the retired donor GLES assets; see the V10 freeze receipt.

internal const val FROZEN_NIKON_PLAYBACK_FEED_VERTEX_ES2 = """#version 100

attribute vec4 aFramePosition;
varying vec2 vTexSamplingCoord;

void main() {
    gl_Position = aFramePosition;
    vTexSamplingCoord = vec2(
        aFramePosition.x * 0.5 + 0.5,
        aFramePosition.y * 0.5 + 0.5
    );
}
"""

internal const val FROZEN_NIKON_PLAYBACK_FEED_FRAGMENT_ES2 = """#version 100

precision highp float;

uniform sampler2D uTexSampler;
uniform sampler2D uLut;
uniform sampler2D uLimitsPaintCube;
uniform sampler2D uLimitsWeightCube;
uniform float uFlipInputY;
// Horizontal flip for a camera pointed back at the operator: 1 mirrors, 0 does not. Folds the
// SAMPLING coordinate, so the picture and every effect read through it flip together.
uniform float uMirror;
uniform float uLutSize;
// 50/50 Log-vs-LUT comparison: 1 = on, and 1 = a vertical boundary (Log left, LUT right)
// against a horizontal one (Log top, LUT bottom). See `SplitComparison` in shared core.
uniform float uSplitOn;
uniform float uSplitVertical;
uniform float uLimitsPaintSize;
uniform float uLimitsWeightSize;
uniform float uLimitsOn;
uniform vec2 uSourceSize;
uniform vec2 uDisplaySize;

uniform float uPeakingOn;
uniform vec3 uPeakingColor;
// Pass 1's output: R = stroke opacity, G = the hairline's, at SOURCE resolution.
// The detector itself lives in `peaking_mask_fragment_es2.glsl`; see its header for why
// it is a separate pass and not an inline block here.
uniform sampler2D uPeakingMask;

uniform float uZebraHighlightOn;
uniform float uZebraHighlight;
uniform vec3 uZebraHighlightColor;
uniform float uZebraMidtoneOn;
uniform float uZebraMidtone;
uniform vec3 uZebraMidtoneColor;

varying vec2 vTexSamplingCoord;

const vec3 LUMA_709 = vec3(0.2126, 0.7152, 0.0722);
const float ATLAS_COLUMNS = 8.0;
// Focus peaking's hairline colour, from `Peaking.underColor`. Every other peaking
// constant belongs to the detector and lives with it, in the mask pass.
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

// One bilinear fetch in source-pixel space, for the reconstruction below.
vec3 sampleSourceAt(vec2 pixel, vec2 sourceSize) {
    return sampleSource(pixel / sourceSize);
}

// Catmull-Rom reconstruction of the live-view frame, used only where the feed is MAGNIFIED.
//
// The camera bounds the frame at XGA, so on a panel taller than the frame every displayed pixel
// is an interpolation. GL_LINEAR reconstructs that with a 2x2 tent, which is what makes an
// upscaled feed look soft. Catmull-Rom is an interpolating cubic — it passes exactly through the
// source samples and carries a mild sharpening lobe — so edges resolve instead of ramping.
//
// This is the Android tier of the iOS present-time upscale, which runs MetalFX Spatial over an
// MPS Lanczos fallback. MetalFX has no Android equivalent; Catmull-Rom is the portable
// Lanczos-class filter, and unlike Lanczos-3 it fits the GLES2 floor device.
//
// Nine taps, not sixteen: each axis' inner pair is fetched as one bilinear sample placed at the
// pair's weighted centroid, which is exact for a separable filter and cuts the fetch count.
vec3 sampleSourceReconstructed(vec2 coordinate, vec2 sourceSize) {
    vec2 samplePosition = coordinate * sourceSize;
    vec2 centre = floor(samplePosition - 0.5) + 0.5;
    vec2 f = samplePosition - centre;

    // Catmull-Rom basis. These sum to exactly 1 for every f, so flat areas cannot shift level.
    vec2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    vec2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    vec2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    vec2 w3 = f * f * (-0.5 + 0.5 * f);

    // The inner pair, collapsed to one bilinear fetch at its centroid. w1 + w2 is bounded away
    // from zero across the whole cell, so this division is safe.
    vec2 w12 = w1 + w2;
    vec2 centre12 = centre + w2 / w12;
    vec2 centre0 = centre - 1.0;
    vec2 centre3 = centre + 2.0;

    vec3 row0 = sampleSourceAt(vec2(centre0.x, centre0.y), sourceSize) * w0.x
        + sampleSourceAt(vec2(centre12.x, centre0.y), sourceSize) * w12.x
        + sampleSourceAt(vec2(centre3.x, centre0.y), sourceSize) * w3.x;
    vec3 row12 = sampleSourceAt(vec2(centre0.x, centre12.y), sourceSize) * w0.x
        + sampleSourceAt(vec2(centre12.x, centre12.y), sourceSize) * w12.x
        + sampleSourceAt(vec2(centre3.x, centre12.y), sourceSize) * w3.x;
    vec3 row3 = sampleSourceAt(vec2(centre0.x, centre3.y), sourceSize) * w0.x
        + sampleSourceAt(vec2(centre12.x, centre3.y), sourceSize) * w12.x
        + sampleSourceAt(vec2(centre3.x, centre3.y), sourceSize) * w3.x;

    vec3 reconstructed = row0 * w0.y + row12 * w12.y + row3 * w3.y;
    // The cubic overshoots at hard edges. Clamping the undershoot keeps a dark ring from going
    // negative and poisoning the luma the grade and scopes read downstream.
    return max(reconstructed, vec3(0.0));
}

// The displayed sample. Reconstruction is for magnification only: below 1:1 the feed is being
// minified, where an interpolating cubic is the wrong tool (it aliases without a prefilter) and
// GL_LINEAR is already correct. The A12-class 720p panel sits on this side of the gate, so the
// floor device pays nothing for this.
vec3 sampleSourceForDisplay(vec2 coordinate) {
    vec2 sourceSize = max(uSourceSize, vec2(1.0));
    if (uDisplaySize.x <= sourceSize.x && uDisplaySize.y <= sourceSize.y) {
        return sampleSource(coordinate);
    }
    return sampleSourceReconstructed(coordinate, sourceSize);
}

// Whether this fragment belongs to the graded half of a 50/50 comparison — always true when the
// comparison is off, so the LUT stays one predicate rather than two code paths. A branch inside an
// existing kernel is close to free; a second pass would not be.
//
// `vTexSamplingCoord` spans exactly the visible image rectangle: the caller sets the viewport to
// `nativeFeedContentRect` before drawing, so 0.5 is the middle of the IMAGE and letterbox, pillarbox
// and chrome are all outside the quad entirely.
//
// Top/bottom uses the same display convention as the zebra block below — GL fragments count up, so
// the top of the display is `coordinate.y == 1`, not 0. NOT the `uFlipInputY` sampling fold: that
// one is about where a texel lives in the input texture, and the operator's "top" is where the
// pixel lands on screen.
bool splitIsGradedSide(vec2 coordinate) {
    if (uSplitOn < 0.5) {
        return true;
    }
    return uSplitVertical > 0.5 ? coordinate.x >= 0.5 : coordinate.y < 0.5;
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

// Morphological closing of the finished stroke, over the element `Peaking.closingOffsets`
// measures: `CIMorphologyMaximum` at radius 1 is a five-point PLUS, not the 3x3 square the
// filter name suggests. Dilate then erode therefore spans the |dx| + |dy| <= 2 diamond, so
// 13 distinct mask reads answer all 25 min-of-max terms.
//
// This is what rejoins the dashes a strict noise gate punches into edges that ARE sharp; a
// line broken into dashes reads as MORE noise than a continuous one even with less ink on
// screen, which is how a stricter setting can look worse. Closing and not opening: the
// strokes are about a pixel wide, so eroding first would delete them along with the specks.
float peakingClosedStroke(vec2 centre, vec2 texel) {
    float m00 = texture2D(uPeakingMask, centre).r;
    float mR = texture2D(uPeakingMask, centre + vec2(texel.x, 0.0)).r;
    float mL = texture2D(uPeakingMask, centre - vec2(texel.x, 0.0)).r;
    float mD = texture2D(uPeakingMask, centre + vec2(0.0, texel.y)).r;
    float mU = texture2D(uPeakingMask, centre - vec2(0.0, texel.y)).r;
    float mRR = texture2D(uPeakingMask, centre + vec2(2.0 * texel.x, 0.0)).r;
    float mLL = texture2D(uPeakingMask, centre - vec2(2.0 * texel.x, 0.0)).r;
    float mDD = texture2D(uPeakingMask, centre + vec2(0.0, 2.0 * texel.y)).r;
    float mUU = texture2D(uPeakingMask, centre - vec2(0.0, 2.0 * texel.y)).r;
    float mRD = texture2D(uPeakingMask, centre + vec2(texel.x, texel.y)).r;
    float mRU = texture2D(uPeakingMask, centre + vec2(texel.x, -texel.y)).r;
    float mLD = texture2D(uPeakingMask, centre + vec2(-texel.x, texel.y)).r;
    float mLU = texture2D(uPeakingMask, centre + vec2(-texel.x, -texel.y)).r;

    // Dilation at each of the element's five offsets...
    float dC = max(max(max(m00, mR), max(mL, mD)), mU);
    float dR = max(max(max(mR, mRR), max(m00, mRD)), mRU);
    float dL = max(max(max(mL, m00), max(mLL, mLD)), mLU);
    float dD = max(max(max(mD, mRD), max(mLD, mDD)), m00);
    float dU = max(max(max(mU, mRU), max(mLU, m00)), mUU);
    // ...then erosion over the same element.
    return min(min(min(dC, dR), min(dL, dD)), dU);
}

void main() {
    // `source` stays the raw fetch: zebra, false colour and the limits paint MEASURE it, and a
    // measurement must describe the frame the camera sent, not a reconstruction of it. iOS keeps
    // the same separation by upscaling at present time, after the bake the scopes read.
    // Folded ONCE, here, and used for every read in SOURCE space — the picture and the peaking
    // mask alike. Folding inside `sampleSource` instead would flip the picture while the mask
    // stayed put, and the strokes would land on the wrong side of the frame.
    //
    // Display-space questions keep the raw coordinate: the split boundary is about where a pixel
    // lands for the operator, and the zebra stripe is screen geometry.
    vec2 sourceCoordinate = vec2(
        mix(vTexSamplingCoord.x, 1.0 - vTexSamplingCoord.x, uMirror),
        vTexSamplingCoord.y
    );
    vec3 source = sampleSource(sourceCoordinate);
    vec3 displaySource = sampleSourceForDisplay(sourceCoordinate);
    vec3 color =
        splitIsGradedSide(vTexSamplingCoord) ? grade(displaySource) : displaySource;

    if (uLimitsOn > 0.5) {
        color = mix(color, limitsPaint(source), limitsWeight(source));
    }

    if (uPeakingOn > 0.5) {
        // Snap to the source pixel grid: the mask has one texel per source pixel, and the
        // closing's offsets are source pixels, so every read has to land on a texel centre.
        // Sampling from a fractional position would bilinear-blend four mask texels and
        // soften the very thing the closing exists to keep continuous.
        vec2 sourceSize = max(uSourceSize, vec2(1.0));
        vec2 texel = 1.0 / sourceSize;
        vec2 centre = (floor(sourceCoordinate * sourceSize) + 0.5) * texel;
        float stroke = peakingClosedStroke(centre, texel);
        // The hairline is NOT closed, matching iOS: morphology is two more passes, and a
        // hairline drawn under the stroke gains almost nothing from being continuous.
        float under = texture2D(uPeakingMask, centre).g;
        // Hairline first at its full ramp opacity, then the stroke over the top of it —
        // `ImageEffectsCompositor.composite`'s two blends, in that order. The hairline is
        // what stops a bright stroke from vanishing into a bright subject.
        color = mix(color, PEAKING_UNDER_COLOR, under);
        color = mix(color, uPeakingColor, stroke);
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
"""

internal const val FROZEN_NIKON_PEAKING_BLUR_FRAGMENT_ES2 = """#version 100

// Pass 1 of 3 of focus peaking: the VERTICAL half of the separable re-blur, once per
// source pixel. One texel carries both rows the operator's 2x2 quad needs —
// xy = the blur centred on this row, zw = the blur centred on the row below — each
// packed to 16 bits.
//
// Why this pass exists at all. The detector's re-blur is separable, but writing it fused
// costs a full 8x8 neighbourhood per pixel (64 taps) because the operator wants the
// blurred value at four positions, not one. Split, the vertical half is 8 taps here and
// the horizontal half is 8 reads in `peaking_mask_fragment_es2.glsl` — 20 taps against 68
// for an identical result. That is the difference between peaking running and not running
// on a floor device: a Mali-G52 at 1024x768 source needs ~2.7 GTexel/s for the fused form
// against roughly 1 available, which presents as a feed that flickers and stops updating.
//
// SPLIT, NOT APPROXIMATED. `Peaking.reblurWeights` sum to exactly 1, and the weight
// function is zero beyond |offset| >= 3.5, so the two vertical blurs this writes are the
// same `vp0`/`vp1` the fused loop accumulated — see the header of the mask pass for the
// algebra. No constant here is new; every one is transcribed from `Peaking` in shared core.
//
// 16-BIT PACKING IS LOAD-BEARING, not caution. The coarse operator takes DIFFERENCES of
// these blurred values, and a blurred field is smooth by construction, so the differences
// are small — an 8-bit intermediate quantises them at 1/255 and swamps the very gradient
// the ratio divides by. Packed, the error is ~1/65025 and lands far below the noise gate.
// A half-float target would be cleaner but throws on an ES2 context, and on the live
// surface that throw tears down the whole GPU path.

precision highp float;

uniform sampler2D uTexSampler;
uniform float uFlipInputY;
uniform vec2 uSourceSize;

varying vec2 vTexSamplingCoord;

const float PEAKING_W0 = 0.382992;
const float PEAKING_W1 = 0.241798;
const float PEAKING_W2 = 0.060662;
const float PEAKING_W3 = 0.006044;

vec3 sampleSource(vec2 coordinate) {
    float y = mix(coordinate.y, 1.0 - coordinate.y, uFlipInputY);
    return texture2D(uTexSampler, vec2(coordinate.x, y)).rgb;
}

// Measured on the RAW source, exactly as the fused detector was — see the mask pass.
float sourceGrey(vec2 coordinate) {
    vec3 color = sampleSource(coordinate);
    return (color.r + color.g + color.b) / 3.0;
}

// MEASURED off `CIGaussianBlur(radius: 1.0)` by impulse response (`Peaking.reblurWeights`);
// near but not equal to a sigma-1.04 Gaussian, which is why it is measured, not derived.
float peakingTapWeight(float offset) {
    float d = abs(offset);
    return d < 0.5 ? PEAKING_W0
        : d < 1.5 ? PEAKING_W1
        : d < 2.5 ? PEAKING_W2
        : d < 3.5 ? PEAKING_W3
        : 0.0;
}

// A weighted mean of greys in [0,1] over weights summing to 1, so the value is in [0,1]
// and needs no scaling before packing.
vec2 pack16(float value) {
    float scaled = clamp(value, 0.0, 1.0) * 255.0;
    float high = floor(scaled);
    return vec2(high, (scaled - high) * 255.0) / 255.0;
}

void main() {
    vec2 sourceSize = max(uSourceSize, vec2(1.0));
    vec2 texel = 1.0 / sourceSize;
    // Snap to the texel centre so each tap is provably one source pixel, whatever the
    // caller sizes this target at — the same snap the fused detector opened with.
    vec2 centre = (floor(vTexSamplingCoord * sourceSize) + 0.5) * texel;

    // Rows -3..+4 cover both blurs: the centred one reaches -3..+3, the shifted one -2..+4.
    float blurAtRow = 0.0;
    float blurAtRowBelow = 0.0;
    for (int row = 0; row < 8; row++) {
        float dy = float(row) - 3.0;
        float g = sourceGrey(centre + vec2(0.0, dy) * texel);
        blurAtRow += peakingTapWeight(dy) * g;
        blurAtRowBelow += peakingTapWeight(dy - 1.0) * g;
    }

    // No inset guard here. The mask pass still zeroes its own border at
    // PEAKING_EDGE_INSET, which is wider than the 4 rows this reaches, so every value it
    // actually consumes was computed from in-bounds taps and matches the fused result
    // exactly. Guarding here as well would only zero pixels the next pass discards.
    gl_FragColor = vec4(pack16(blurAtRow), pack16(blurAtRowBelow));
}
"""

internal const val FROZEN_NIKON_PEAKING_MASK_FRAGMENT_ES2 = """#version 100

// Pass 2 of 3 of focus peaking: the HORIZONTAL half of the re-blur, the operator, and the
// ramps — evaluated ONCE PER SOURCE PIXEL into an offscreen mask.
// R = the painted stroke's opacity, G = the dark hairline's.
//
// The vertical half already ran in `peaking_blur_fragment_es2.glsl`, which is why this
// reads 8 texels instead of walking a 64-tap neighbourhood. The algebra of that split,
// once, because it is the reason two shaders exist:
//
//   the fused loop accumulated, per column dx,
//     vp0 = SUM over dy of w(dy)     * g(x+dx, y+dy)   -- blur centred on row y
//     vp1 = SUM over dy of w(dy - 1) * g(x+dx, y+dy)   -- blur centred on row y+1
//   then folded each into the four quad positions with the horizontal weights w(dx) and
//   w(dx-1). Those two sums depend on the COLUMN alone, so the blur pass computes them
//   per pixel and hands both over in one texel (xy and zw, 16 bits each). What is left
//   here is the horizontal fold, unchanged and exact — the same four `b**` values, from 8
//   reads rather than 64 taps.
//
// w(offset) is zero beyond |offset| >= 3.5, so vp1 at row y is identically the centred
// blur at row y+1; nothing is approximated by carrying it in the same texel.
//
// Split out of the composite shader for one reason. iOS closes the finished stroke
// (`Peaking.maskClosingRadius`), which rejoins the dashes a strict noise gate punches
// into edges that ARE sharp — measured, fragmentation 18.9% -> 1.6% at equal ink, and
// it is what makes the wide sensitivity ladder usable at all. Closing needs the mask at
// 13 neighbouring points (`Peaking.closingOffsets` is a five-point PLUS, so dilate then
// erode spans the |dx|+|dy| <= 2 diamond), and each of those points needs its own 8x8
// re-blur neighbourhood. Shared, that is a 12x12 grey grid and ~130 live floats against
// the ~25 one evaluation needs — a register-pressure cliff, not a tap-count problem, and
// a pass boundary in any renderer. Memoising the mask turns the closing into 13 cheap
// texture reads.
//
// It also moves the detector off the display grid. The composite pass runs per DISPLAY
// pixel; this runs per SOURCE pixel, which for a 1024x576 feed shown at 1920x1080 is
// about a third of the fragments — so two passes cost less than the one they replace.
//
// Every constant is from `Peaking` in shared core, where the derivation, the calibration
// tables and the measurements live. `Peaking.overlay` is the reference this transcribes,
// and `RunnerTests` checks that reference against the live iOS Core Image graph
// pixel-for-pixel, so the chain from here to what an iPhone renders is closed.

precision highp float;

uniform sampler2D uTexSampler;
// The vertical halves from pass 1, already on this pass's own grid — sampled straight,
// with no flip: `uFlipInputY` belongs to reads of the SOURCE, and pass 1 has applied it.
uniform sampler2D uPeakingBlur;
uniform float uFlipInputY;
uniform vec2 uSourceSize;
uniform float uPeakingRatioThreshold;
uniform float uPeakingNoiseGate;

varying vec2 vTexSamplingCoord;

const float PEAKING_EDGE_INSET = 6.0;
const float PEAKING_W0 = 0.382992;
const float PEAKING_W1 = 0.241798;
const float PEAKING_W2 = 0.060662;
const float PEAKING_W3 = 0.006044;
const float PEAKING_RATIO_CEILING = 4.0;
const float PEAKING_AA = 0.12;
const float PEAKING_UNDER_OFFSET = 0.5;
const float PEAKING_GATE_FLOOR = 0.7;

vec3 sampleSource(vec2 coordinate) {
    float y = mix(coordinate.y, 1.0 - coordinate.y, uFlipInputY);
    return texture2D(uTexSampler, vec2(coordinate.x, y)).rgb;
}

// Focus peaking measures BLUR RADIUS, not edge contrast. A gradient magnitude scales
// with amplitude as much as with focus, so a bright defocused highlight rim outranks
// genuinely sharp low-contrast detail. Running the operator on the source and again on a
// re-blurred copy, then dividing, cancels amplitude exactly and leaves a number that
// depends only on how blurred the edge is. Measured on the RAW source.
float sourceGrey(vec2 coordinate) {
    vec3 color = sampleSource(coordinate);
    return (color.r + color.g + color.b) / 3.0;
}

// Weight of a tap `offset` pixels from the centre of the separable re-blur, zero beyond
// its reach. MEASURED off `CIGaussianBlur(radius: 1.0)` by impulse response — see
// `Peaking.reblurWeights`; it is near but not equal to a sigma-1.04 Gaussian, which is
// why the weights are measured and not derived. A function rather than an indexed array
// so the kernel needs no local array at all.
float peakingTapWeight(float offset) {
    float d = abs(offset);
    return d < 0.5 ? PEAKING_W0
        : d < 1.5 ? PEAKING_W1
        : d < 2.5 ? PEAKING_W2
        : d < 3.5 ? PEAKING_W3
        : 0.0;
}

// Inverse of `pack16` in the blur pass: the high byte plus the low byte's 1/255 share.
// NB `packed` is a reserved word in GLSL ES 1.00, so the pair cannot be named that.
float unpack16(vec2 pair) {
    return pair.x + pair.y / 255.0;
}

// The operator: a squared Roberts cross over the 2x2 quad anchored at the pixel,
// reproducing `CIEdges`. SQUARED — a 0.2 step gives 0.08, a 0.4 step 0.32 — which is the
// domain every threshold in `Peaking` lives in.
float peakingRoberts(float a, float b, float c, float d) {
    float d1 = d - a;
    float d2 = c - b;
    return d1 * d1 + d2 * d2;
}

void main() {
    vec2 sourceSize = max(uSourceSize, vec2(1.0));
    vec2 inset = vec2(PEAKING_EDGE_INSET) / sourceSize;
    if (
        vTexSamplingCoord.x < inset.x
        || vTexSamplingCoord.y < inset.y
        || vTexSamplingCoord.x >= 1.0 - inset.x
        || vTexSamplingCoord.y >= 1.0 - inset.y
    ) {
        // The border the kernels would sample outside of. Zero here is load-bearing: the
        // closing pass erodes against it, so the overlay stops exactly at the inset.
        gl_FragColor = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }

    // This pass is already one fragment per source pixel, so the snap is an identity —
    // kept so the taps are provably on texel centres whatever the caller sizes us at.
    vec2 texel = 1.0 / sourceSize;
    vec2 centre = (floor(vTexSamplingCoord * sourceSize) + 0.5) * texel;

    // The horizontal fold. Columns -3..+4 are what the two horizontal weights between them
    // reach, and each read already carries both of the quad's rows, so the four `b**` come
    // out of 8 texels. Same values as the fused 8x8 loop, a third of the bandwidth.
    float b00 = 0.0;
    float b10 = 0.0;
    float b01 = 0.0;
    float b11 = 0.0;
    for (int col = 0; col < 8; col++) {
        float dx = float(col) - 3.0;
        vec4 rows = texture2D(uPeakingBlur, centre + vec2(dx, 0.0) * texel);
        float vp0 = unpack16(rows.xy);
        float vp1 = unpack16(rows.zw);
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
        sourceGrey(centre + vec2(1.0, 1.0) * texel)
    );
    float ratio = min(fine / max(coarse, 1e-9), PEAKING_RATIO_CEILING);
    // Noise is not lens-blurred, so it always reads as perfectly sharp; the ratio cannot
    // reject it and this gate is what keeps shadows from sparkling. It arrives already
    // scaled for the feed's encoding, so there is no mode policy here.
    float gate = clamp(
        (coarse - uPeakingNoiseGate * PEAKING_GATE_FLOOR)
            / max(uPeakingNoiseGate * (1.0 - PEAKING_GATE_FLOOR), 1e-9),
        0.0,
        1.0
    );
    // LINEAR ramps, deliberately not smoothstep: Core Image reaches these with a
    // scale-and-clamp pair, and on a ramp this narrow the Hermite curve is a visible
    // difference in stroke weight rather than a rounding one.
    float stroke = clamp((ratio - uPeakingRatioThreshold) / PEAKING_AA, 0.0, 1.0) * gate;
    float under = clamp(
        (ratio - (uPeakingRatioThreshold - PEAKING_AA * PEAKING_UNDER_OFFSET)) / PEAKING_AA,
        0.0,
        1.0
    ) * gate;

    gl_FragColor = vec4(stroke, under, 0.0, 1.0);
}
"""
