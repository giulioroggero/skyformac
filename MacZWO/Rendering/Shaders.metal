#include <metal_stdlib>
using namespace metal;

/// Full-screen triangle vertex shader — no vertex buffer needed, positions are derived from
/// `vertex_id`. Used to blit the compute-processed frame texture to the MTKView's drawable.
struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut fullscreenTriangleVertex(uint vertexID [[vertex_id]]) {
    // Standard "big triangle" trick: 3 vertices that cover the whole viewport, clipped by
    // the rasterizer, avoiding a vertex/index buffer for a full-screen blit.
    const float2 positions[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    VertexOut out;
    out.position = float4(positions[vertexID], 0, 1);
    out.uv = positions[vertexID] * float2(0.5, -0.5) + 0.5;
    return out;
}

fragment float4 blitFragment(VertexOut in [[stage_in]], texture2d<float, access::sample> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return tex.sample(s, in.uv);
}

/// Per-pixel black/white point stretch parameters shared by the mono and debayer kernels.
struct StretchParams {
    float blackPoint; // normalized 0...1
    float whitePoint; // normalized 0...1
};

inline float applyStretch(float normalizedValue, constant StretchParams &stretch) {
    float white = max(stretch.whitePoint, stretch.blackPoint + (1.0 / 65535.0));
    float t = (normalizedValue - stretch.blackPoint) / (white - stretch.blackPoint);
    return saturate(t);
}

/// Stretches a mono RAW8/RAW16 texture (`r8Unorm`/`r16Unorm`, both sample as normalized
/// float in Metal) into an RGBA8 display texture. One thread per pixel.
kernel void stretchMono(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    constant StretchParams &stretch [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= source.get_width() || gid.y >= source.get_height()) { return; }
    float raw = source.read(gid).r;
    float display = applyStretch(raw, stretch);
    destination.write(float4(display, display, display, 1.0), gid);
}

/// Bayer pattern identifiers, matching `ASI_BAYER_PATTERN` (RG=0, BG=1, GR=2, GB=3).
inline bool isRedAt(uint2 p, uint pattern) {
    bool evenX = (p.x % 2) == 0;
    bool evenY = (p.y % 2) == 0;
    switch (pattern) {
        case 0: return evenX && evenY;   // RGGB
        case 1: return !evenX && !evenY; // BGGR (blue at even,even; red at odd,odd)
        case 2: return !evenX && evenY;  // GRBG
        default: return evenX && !evenY; // GBRG
    }
}

inline bool isBlueAt(uint2 p, uint pattern) {
    bool evenX = (p.x % 2) == 0;
    bool evenY = (p.y % 2) == 0;
    switch (pattern) {
        case 0: return !evenX && !evenY; // RGGB
        case 1: return evenX && evenY;   // BGGR
        case 2: return evenX && !evenY;  // GRBG
        default: return !evenX && evenY; // GBRG
    }
}

inline float readClamped(texture2d<float, access::read> tex, int x, int y) {
    uint width = tex.get_width();
    uint height = tex.get_height();
    uint cx = uint(clamp(x, 0, int(width) - 1));
    uint cy = uint(clamp(y, 0, int(height) - 1));
    return tex.read(uint2(cx, cy)).r;
}

/// GPU bilinear Bayer demosaic + black/white stretch, mirroring `Debayer.swift`'s CPU
/// algorithm exactly (same edge-clamp policy) so GPU and CPU output match pixel-for-pixel.
kernel void debayerAndStretch(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    constant StretchParams &stretch [[buffer(0)]],
    constant uint &bayerPattern [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= source.get_width() || gid.y >= source.get_height()) { return; }
    int x = int(gid.x);
    int y = int(gid.y);

    float r, g, b;
    float here = source.read(gid).r;

    if (isRedAt(gid, bayerPattern)) {
        r = here;
        g = (readClamped(source, x - 1, y) + readClamped(source, x + 1, y)
             + readClamped(source, x, y - 1) + readClamped(source, x, y + 1)) * 0.25;
        b = (readClamped(source, x - 1, y - 1) + readClamped(source, x + 1, y - 1)
             + readClamped(source, x - 1, y + 1) + readClamped(source, x + 1, y + 1)) * 0.25;
    } else if (isBlueAt(gid, bayerPattern)) {
        b = here;
        g = (readClamped(source, x - 1, y) + readClamped(source, x + 1, y)
             + readClamped(source, x, y - 1) + readClamped(source, x, y + 1)) * 0.25;
        r = (readClamped(source, x - 1, y - 1) + readClamped(source, x + 1, y - 1)
             + readClamped(source, x - 1, y + 1) + readClamped(source, x + 1, y + 1)) * 0.25;
    } else {
        g = here;
        bool leftRightIsRed = isRedAt(uint2(uint(max(x - 1, 0)), gid.y), bayerPattern)
            || isRedAt(uint2(uint(x + 1), gid.y), bayerPattern);
        if (leftRightIsRed) {
            r = (readClamped(source, x - 1, y) + readClamped(source, x + 1, y)) * 0.5;
            b = (readClamped(source, x, y - 1) + readClamped(source, x, y + 1)) * 0.5;
        } else {
            b = (readClamped(source, x - 1, y) + readClamped(source, x + 1, y)) * 0.5;
            r = (readClamped(source, x, y - 1) + readClamped(source, x, y + 1)) * 0.5;
        }
    }

    float3 rgb = float3(applyStretch(r, stretch), applyStretch(g, stretch), applyStretch(b, stretch));
    destination.write(float4(rgb, 1.0), gid);
}

/// Parallel histogram: each threadgroup accumulates into threadgroup memory, then atomically
/// adds into the 256-bucket device buffer. Replaces `HistogramComputer`'s CPU pass.
kernel void histogramReduce(
    texture2d<float, access::read> source [[texture(0)]],
    device atomic_uint *buckets [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 tid [[thread_position_in_threadgroup]],
    threadgroup atomic_uint *localBuckets [[threadgroup(0)]]
) {
    uint localIndex = tid.y * 16 + tid.x;
    if (localIndex < 256) {
        atomic_store_explicit(&localBuckets[localIndex], 0, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (gid.x < source.get_width() && gid.y < source.get_height()) {
        float value = source.read(gid).r;
        uint bucket = min(uint(value * 255.0), 255u);
        atomic_fetch_add_explicit(&localBuckets[bucket], 1, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (localIndex < 256) {
        uint count = atomic_load_explicit(&localBuckets[localIndex], memory_order_relaxed);
        if (count > 0) {
            atomic_fetch_add_explicit(&buckets[localIndex], count, memory_order_relaxed);
        }
    }
}
