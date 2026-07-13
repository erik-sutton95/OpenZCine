#version 460 core
#include <flutter/runtime_effect.glsl>

// 3D LUT applied to a video frame. The cube is packed into a 2D atlas of `n`
// horizontally-tiled blue slices (width = n*n, height = n); within a tile
// x = red, y = green. Full MANUAL trilinear interpolation (8 taps at texel
// centers) so it does not depend on the platform's sampler filtering.

uniform vec2 uSize;        // draw-rect size (frame fills it)
uniform float uLutSize;    // n (e.g. 33)
uniform sampler2D uImage;  // the video frame
uniform sampler2D uLut;    // the LUT atlas

out vec4 fragColor;

vec3 texelAt(float ri, float gi, float bi, float n) {
  float w = n * n;
  float u = (bi * n + ri + 0.5) / w;
  float v = (gi + 0.5) / n;
  return texture(uLut, vec2(u, v)).rgb;
}

vec3 sliceBilinear(float rf, float gf, float bi, float n) {
  float r0 = floor(rf);
  float r1 = min(r0 + 1.0, n - 1.0);
  float fr = rf - r0;
  float g0 = floor(gf);
  float g1 = min(g0 + 1.0, n - 1.0);
  float fg = gf - g0;
  vec3 c00 = texelAt(r0, g0, bi, n);
  vec3 c10 = texelAt(r1, g0, bi, n);
  vec3 c01 = texelAt(r0, g1, bi, n);
  vec3 c11 = texelAt(r1, g1, bi, n);
  return mix(mix(c00, c10, fr), mix(c01, c11, fr), fg);
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
  vec4 src = texture(uImage, uv);
  vec3 c = clamp(src.rgb, 0.0, 1.0);
  float n = uLutSize;
  float rf = c.r * (n - 1.0);
  float gf = c.g * (n - 1.0);
  float bf = c.b * (n - 1.0);
  float b0 = floor(bf);
  float b1 = min(b0 + 1.0, n - 1.0);
  float fb = bf - b0;
  vec3 s0 = sliceBilinear(rf, gf, b0, n);
  vec3 s1 = sliceBilinear(rf, gf, b1, n);
  fragColor = vec4(mix(s0, s1, fb), src.a);
}
