#version 460 core

// Hillshade, first pass: the terrain's slope at every texel of one DEM
// tile, as the style spec's `hillshade` layer needs it.
//
// Input: the tile's RGB-encoded elevations with a 2-texel border taken
// from its neighbours (or repeated from its own edge where a neighbour
// is missing), (dim + 4)² texels. Output: (dim + 2)² texels, the tile
// plus a 1-texel border, so that the second pass can interpolate slopes
// across the tile edge. Red and green hold the west→east and
// north→south slope, offset so that flat ground is 128/255 — a value
// eight bits store exactly.

#include <flutter/runtime_effect.glsl>

precision highp float;

// Uniforms are declared vectors first, widest first, so that every one
// sits on its natural alignment whatever packing a backend applies.

// Factors turning 0–255 channel values into metres (red, green, blue;
// w unused). The encoding's base shift cancels in a slope, so it is not
// needed.
uniform vec4 uUnpack;
// The input's size in texels: dim + 4.
uniform float uSize;
// Metres-per-texel normalisation and zoom-dependent exaggeration,
// precomputed on the CPU (see `HillshadeRenderer.slopeScale`).
uniform float uScale;
uniform sampler2D uDem;

out vec4 fragColor;

// The 0–255 channel values of the input texel [texel] columns/rows from
// the top-left corner. Sampled at the texel's centre, so the result is
// the texel itself whatever filter the sampler uses.
vec3 channels(vec2 texel) {
  vec2 uv = (texel + 0.5) / uSize;
#if defined(IMPELLER_TARGET_OPENGLES) && \
    !defined(IMPELLER_OPENGLES_UNFLIPPED_DEPRECATED)
  // The input is `toImageSync` output, which Impeller's OpenGL ES
  // backend stored bottom-up before Flutter defined this macro.
  uv.y = 1.0 - uv.y;
#endif
  return floor(texture(uDem, uv).rgb * 255.0 + 0.5);
}

void main() {
  // Output texel i sits on input texel i + 1.
  vec2 pos = floor(FlutterFragCoord().xy) + 1.0;

  vec3 a = channels(pos + vec2(-1.0, -1.0));
  vec3 b = channels(pos + vec2(0.0, -1.0));
  vec3 c = channels(pos + vec2(1.0, -1.0));
  vec3 d = channels(pos + vec2(-1.0, 0.0));
  vec3 f = channels(pos + vec2(1.0, 0.0));
  vec3 g = channels(pos + vec2(-1.0, 1.0));
  vec3 h = channels(pos + vec2(0.0, 1.0));
  vec3 i = channels(pos + vec2(1.0, 1.0));

  // A Sobel kernel. Decoding is linear, so the kernel runs on the raw
  // channel values — small integers, exact at any float precision — and
  // only its result is decoded.
  vec3 dx = (c + f + f + i) - (a + d + d + g);
  vec3 dy = (g + h + h + i) - (a + b + b + c);
  vec2 deriv = vec2(dot(dx, uUnpack.rgb), dot(dy, uUnpack.rgb)) * uScale;

  fragColor = vec4(clamp(deriv / 8.0 + 128.0 / 255.0, 0.0, 1.0), 1.0, 1.0);
}
