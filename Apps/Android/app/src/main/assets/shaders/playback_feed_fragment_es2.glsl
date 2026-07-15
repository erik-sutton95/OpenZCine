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
uniform vec4 uDeLogCurve0To3;
uniform float uDeLogCurve4;
uniform float uPeakingThreshold;
uniform float uPeakingRamp;

uniform float uZebraHighlightOn;
uniform float uZebraHighlight;
uniform vec3 uZebraHighlightColor;
uniform float uZebraMidtoneOn;
uniform float uZebraMidtone;
uniform vec3 uZebraMidtoneColor;

varying vec2 vTexSamplingCoord;

const vec3 LUMA_709 = vec3(0.2126, 0.7152, 0.0722);
const float ATLAS_COLUMNS = 8.0;
const float DEFOCUS_REJECTION = 1.35;
const float PEAKING_EDGE_INSET = 10.4;
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

float monotoneTone(float y0, float y1, float y2, float y3, float fraction) {
    float m1 = 0.5 * (y2 - y0);
    float m2 = 0.5 * (y3 - y1);
    float t2 = fraction * fraction;
    float t3 = t2 * fraction;
    float value =
        (2.0 * t3 - 3.0 * t2 + 1.0) * y1
        + (t3 - 2.0 * t2 + fraction) * m1
        + (-2.0 * t3 + 3.0 * t2) * y2
        + (t3 - t2) * m2;
    return clamp(value, min(y1, y2), max(y1, y2));
}

float deLogGrey(vec2 coordinate) {
    vec3 color = sampleSource(coordinate);
    float position = clamp((color.r + color.g + color.b) / 3.0, 0.0, 1.0) * 4.0;
    float segment = min(floor(position), 3.0);
    float fraction = position - segment;
    if (segment < 0.5) {
        return monotoneTone(
            uDeLogCurve0To3.x,
            uDeLogCurve0To3.x,
            uDeLogCurve0To3.y,
            uDeLogCurve0To3.z,
            fraction
        );
    }
    if (segment < 1.5) {
        return monotoneTone(
            uDeLogCurve0To3.x,
            uDeLogCurve0To3.y,
            uDeLogCurve0To3.z,
            uDeLogCurve0To3.w,
            fraction
        );
    }
    if (segment < 2.5) {
        return monotoneTone(
            uDeLogCurve0To3.y,
            uDeLogCurve0To3.z,
            uDeLogCurve0To3.w,
            uDeLogCurve4,
            fraction
        );
    }
    return monotoneTone(
        uDeLogCurve0To3.z,
        uDeLogCurve0To3.w,
        uDeLogCurve4,
        uDeLogCurve4,
        fraction
    );
}

float gradientMagnitude(vec2 coordinate, float sourceRadius) {
    vec2 delta = vec2(sourceRadius) / max(uSourceSize, vec2(1.0));
    float topLeft = deLogGrey(coordinate + vec2(-delta.x, -delta.y));
    float topCenter = deLogGrey(coordinate + vec2(0.0, -delta.y));
    float topRight = deLogGrey(coordinate + vec2(delta.x, -delta.y));
    float middleLeft = deLogGrey(coordinate + vec2(-delta.x, 0.0));
    float middleRight = deLogGrey(coordinate + vec2(delta.x, 0.0));
    float bottomLeft = deLogGrey(coordinate + vec2(-delta.x, delta.y));
    float bottomCenter = deLogGrey(coordinate + vec2(0.0, delta.y));
    float bottomRight = deLogGrey(coordinate + vec2(delta.x, delta.y));
    float gx =
        -topLeft - 2.0 * middleLeft - bottomLeft
        + topRight + 2.0 * middleRight + bottomRight;
    float gy =
        -topLeft - 2.0 * topCenter - topRight
        + bottomLeft + 2.0 * bottomCenter + bottomRight;
    return length(vec2(gx, gy)) / (8.0 * sourceRadius);
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
            float fine = gradientMagnitude(vTexSamplingCoord, 0.8);
            float coarse = gradientMagnitude(vTexSamplingCoord, 2.6);
            float response = fine - DEFOCUS_REJECTION * coarse;
            float mask = clamp(
                (response - uPeakingThreshold) * uPeakingRamp,
                0.0,
                1.0
            );
            color = mix(color, uPeakingColor, mask);
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
