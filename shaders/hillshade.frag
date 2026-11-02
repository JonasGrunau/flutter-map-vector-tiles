#version 460 core

// Hillshade, second pass: shades every pixel of a DEM tile's area from
// the slopes `hillshade_prepare.frag` computed, with the illumination,
// colours and method of a style's `hillshade` layer. Output is
// premultiplied, drawn over whatever lies below the layer.

#include <flutter/runtime_effect.glsl>

precision highp float;

// Uniforms are declared vectors first, widest first, so that every one
// sits on its natural alignment whatever packing a backend applies.

// Per light: azimuth (radians, the direction the light comes from, 0 =
// north, clockwise, plus π as MapLibre's shaders take it) and altitude
// (radians above the horizon).
uniform vec4 uAzimuths;
uniform vec4 uAltitudes;
uniform vec4 uAccent;
uniform vec4 uShadow0;
uniform vec4 uShadow1;
uniform vec4 uShadow2;
uniform vec4 uShadow3;
uniform vec4 uHighlight0;
uniform vec4 uHighlight1;
uniform vec4 uHighlight2;
uniform vec4 uHighlight3;
// Maps the fragment's local position to its place in the DEM tile, 0–1
// from the tile's top-left corner: tile = uTile0 + (pos - uOrigin) *
// uTileScale. Kept relative to a point near the drawn area so that the
// numbers stay small even when the tile is many times the canvas.
uniform vec2 uOrigin;
uniform vec2 uTile0;
uniform vec2 uTileScale;
// Latitude of the tile's top and bottom edge, in degrees.
uniform vec2 uLatRange;
// The slope image's size in texels: the DEM tile's + 2.
uniform float uSlopeSize;
// 0 standard, 1 basic, 2 combined, 3 igor, 4 multidirectional.
uniform float uMethod;
uniform float uExaggeration;
// 1 for `resampling: nearest`, 0 for linear.
uniform float uNearest;
// How many of the four light slots above are used (multidirectional).
uniform float uLights;
uniform sampler2D uSlope;

out vec4 fragColor;

const float PI = 3.141592653589793;

vec2 slopeTexel(vec2 texel) {
  vec2 uv = (texel + 0.5) / uSlopeSize;
#if defined(IMPELLER_TARGET_OPENGLES) && \
    !defined(IMPELLER_OPENGLES_UNFLIPPED_DEPRECATED)
  // The slopes are `toImageSync` output, which Impeller's OpenGL ES
  // backend stored bottom-up before Flutter defined this macro.
  uv.y = 1.0 - uv.y;
#endif
  return texture(uSlope, uv).rg;
}

// The slope at [t], in slope-image texel units. Interpolated by hand
// from texel centres, so the result does not depend on the filter the
// sampler happens to use on this backend.
vec2 slopeAt(vec2 t) {
  if (uNearest > 0.5) return slopeTexel(floor(t));
  vec2 q = t - 0.5;
  vec2 i0 = floor(q);
  vec2 w = q - i0;
  vec2 top = mix(slopeTexel(i0), slopeTexel(i0 + vec2(1.0, 0.0)), w.x);
  vec2 bottom =
      mix(slopeTexel(i0 + vec2(0.0, 1.0)), slopeTexel(i0 + vec2(1.0, 1.0)), w.x);
  return mix(top, bottom, w.y);
}

float aspectOf(vec2 deriv) {
  return deriv.x != 0.0 ? atan(deriv.y, -deriv.x)
                        : PI / 2.0 * (deriv.y > 0.0 ? 1.0 : -1.0);
}

// Lambertian light from [azimuth]/[altitude] on a surface of slope
// [deriv], mapped to the shadow colour below one half and the highlight
// colour above it (GDAL's `gdaldem hillshade`, with transparency in the
// middle instead of grey).
vec4 basicLight(vec2 deriv, float cosAz, float sinAz, float altitude,
                vec4 shadow, vec4 highlight) {
  float cosAlt = cos(altitude);
  float sinAlt = sin(altitude);
  float cang = (sinAlt - (deriv.y * cosAz * cosAlt - deriv.x * sinAz * cosAlt)) /
               sqrt(1.0 + dot(deriv, deriv));
  float shade = clamp(cang, 0.0, 1.0);
  return shade > 0.5 ? highlight * (2.0 * shade - 1.0)
                     : shadow * (1.0 - 2.0 * shade);
}

vec4 standard(vec2 deriv) {
  float azimuth = uAzimuths.x;
  float slope = atan(0.625 * length(deriv));
  float aspect = aspectOf(deriv);
  float intensity = uExaggeration;
  // Slope scaled exponentially by intensity, so that higher intensities
  // shade more opaquely.
  float base = 1.875 - intensity * 1.75;
  float maxValue = 0.5 * PI;
  float scaledSlope = intensity != 0.5
      ? ((pow(base, slope) - 1.0) / (pow(base, maxValue) - 1.0)) * maxValue
      : slope;
  // The accent eases in with the slope's cosine, the shade eases out
  // with its sine; intensities below one half fade both.
  float fade = clamp(intensity * 2.0, 0.0, 1.0);
  vec4 accent = (1.0 - cos(scaledSlope)) * uAccent * fade;
  float shade = abs(mod((aspect + azimuth) / PI + 0.5, 2.0) - 1.0);
  vec4 shadeColor = mix(uShadow0, uHighlight0, shade) * sin(scaledSlope) * fade;
  return accent * (1.0 - shadeColor.a) + shadeColor;
}

vec4 basic(vec2 deriv) {
  deriv = deriv * uExaggeration * 2.0;
  float azimuth = uAzimuths.x;
  return basicLight(deriv, cos(azimuth), sin(azimuth), uAltitudes.x, uShadow0,
                    uHighlight0);
}

vec4 combined(vec2 deriv) {
  deriv = deriv * uExaggeration * 2.0;
  float azimuth = uAzimuths.x;
  float cosAlt = cos(uAltitudes.x);
  float sinAlt = sin(uAltitudes.x);
  float cang = acos(clamp(
      (sinAlt - (deriv.y * cos(azimuth) * cosAlt -
                 deriv.x * sin(azimuth) * cosAlt)) /
          sqrt(1.0 + dot(deriv, deriv)),
      -1.0, 1.0));
  cang = clamp(cang, 0.0, PI / 2.0);
  float steepness = atan(length(deriv)) * 4.0 / PI / PI;
  return uShadow0 * (cang * steepness) +
         uHighlight0 * ((PI / 2.0 - cang) * steepness);
}

vec4 igor(vec2 deriv) {
  deriv = deriv * uExaggeration * 2.0;
  float aspect = aspectOf(deriv);
  float azimuth = uAzimuths.x;
  float slopeStrength = atan(length(deriv)) * 2.0 / PI;
  float aspectStrength =
      1.0 - abs(mod((aspect + azimuth) / PI + 0.5, 2.0) - 1.0);
  return uShadow0 * (slopeStrength * aspectStrength) +
         uHighlight0 * (slopeStrength * (1.0 - aspectStrength));
}

// [basic], once per light, averaged.
vec4 multidirectional(vec2 deriv) {
  deriv = deriv * uExaggeration * 2.0;
  vec4 sum = basicLight(deriv, cos(uAzimuths.x), sin(uAzimuths.x),
                        uAltitudes.x, uShadow0, uHighlight0);
  if (uLights > 1.5) {
    sum += basicLight(deriv, cos(uAzimuths.y), sin(uAzimuths.y), uAltitudes.y,
                      uShadow1, uHighlight1);
  }
  if (uLights > 2.5) {
    sum += basicLight(deriv, cos(uAzimuths.z), sin(uAzimuths.z), uAltitudes.z,
                      uShadow2, uHighlight2);
  }
  if (uLights > 3.5) {
    sum += basicLight(deriv, cos(uAzimuths.w), sin(uAzimuths.w), uAltitudes.w,
                      uShadow3, uHighlight3);
  }
  return sum / uLights;
}

void main() {
  vec2 tile = uTile0 + (FlutterFragCoord().xy - uOrigin) * uTileScale;
  vec2 encoded = slopeAt(tile * (uSlopeSize - 2.0) + 1.0);

  // Mercator stretches slopes by 1 / cos(latitude); undo it.
  float latitude = mix(uLatRange.x, uLatRange.y, tile.y);
  vec2 deriv = (encoded - 128.0 / 255.0) * 8.0 / cos(radians(latitude));

  if (uMethod < 0.5) {
    fragColor = standard(deriv);
  } else if (uMethod < 1.5) {
    fragColor = basic(deriv);
  } else if (uMethod < 2.5) {
    fragColor = combined(deriv);
  } else if (uMethod < 3.5) {
    fragColor = igor(deriv);
  } else {
    fragColor = multidirectional(deriv);
  }
}
