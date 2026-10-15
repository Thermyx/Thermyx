// Animated topographic contours: the background of thermyx.web.app, a port
// of the React Bits "Topography" component. Same field, palette, line width,
// glow, contrast and grain as the website's three.js shader; time-varying
// control points come from TopographyBackground.swift.

#include <metal_stdlib>
using namespace metal;

namespace topo {

constant float3 low = float3(0x2C, 0x9C, 0xF0) / 255.0;   // signal blue
constant float3 mid = float3(0xFF, 0x6A, 0x13) / 255.0;   // ember
constant float3 high = float3(0xFF, 0x9B, 0x3D) / 255.0;  // amber

constant float morphAmount = 3.0;
constant float bands = 2.0;
constant float thickness = 0.01;
constant float glowAmount = 0.5;
constant float contrast = 3.0;
constant float grain = 0.05;

inline float bez(float t, float4 c) {
    float w = 6.2831853 * t;
    return 0.5 * (c.x * sin(w) + c.y * cos(w) + c.z * sin(2.0 * w) + c.w * cos(2.0 * w));
}

/// Elevation at a uv (origin bottom left, equal units on both axes), plus an
/// optional bump.
inline float field(float2 uv, float4 a, float4 b, float4 c, float4 d, float4 bump) {
    float2 p = float2(bez(uv.x, a), bez(uv.x, b));
    float2 q = float2(bez(uv.y, c), bez(uv.y, d));
    float fv = distance(p, q);
    float2 delta = uv - bump.xy;
    float r = max(bump.z, 0.001);
    return fv + exp(-dot(delta, delta) / (r * r)) * bump.w;
}

inline float3 elevationColor(float e) {
    float3 c = mix(low, mid, smoothstep(0.0, 0.5, e));
    return mix(c, high, smoothstep(0.5, 1.0, e));
}

} // namespace topo

/// `position` is in points, top-left origin. `pixel` is one device pixel in
/// points, so the anti-aliasing and grain stay one pixel wide on any screen.
/// `bump` is (u, v, radius, strength); a strength of 0 turns it off.
[[ stitchable ]] half4 topography(float2 position, half4 color,
                                  float2 size, float time, float opacity, float pixel,
                                  float4 ctrlA, float4 ctrlB, float4 ctrlC, float4 ctrlD,
                                  float4 bump) {
    // Square units, scaled by the geometric mean of the sides, so contours
    // keep their shape on a tall phone instead of squeezing sideways.
    float unit = sqrt(max(size.x * size.y, 1.0));
    float2 uv = float2(position.x, size.y - position.y) / unit;
    float f = topo::field(uv, ctrlA, ctrlB, ctrlC, ctrlD, bump) * topo::bands;

    // fwidth(f), from neighbours one device pixel away.
    float step = pixel / unit;
    float fx = topo::field(uv + float2(step, 0.0), ctrlA, ctrlB, ctrlC, ctrlD, bump) * topo::bands;
    float fy = topo::field(uv + float2(0.0, step), ctrlA, ctrlB, ctrlC, ctrlD, bump) * topo::bands;
    float aa = abs(fx - f) + abs(fy - f) + 0.0001;

    float frac = fract(f);
    float lineDistance = min(frac, 1.0 - frac);
    float mask = 1.0 - smoothstep(topo::thickness - aa, topo::thickness + aa, lineDistance);
    float glowRadius = topo::thickness + topo::glowAmount * 0.5 + aa;
    float glow = 1.0 - smoothstep(topo::thickness, glowRadius, lineDistance);
    float elevation = clamp(f / topo::bands / (topo::morphAmount * 2.5 + 0.001), 0.0, 1.0);

    float coverage = pow(clamp(mask + glow * 0.55, 0.0, 1.0), topo::contrast);
    float2 devicePixel = position / pixel;
    float g = fract(precise::sin(dot(devicePixel, float2(12.9898, 78.233)) + time) * 43758.5453);
    float alpha = clamp(coverage + (g - 0.5) * topo::grain, 0.0, 1.0) * opacity;

    // Premultiplied, so it composites over the black page like the site.
    return half4(half3(topo::elevationColor(elevation) * alpha), half(alpha));
}
