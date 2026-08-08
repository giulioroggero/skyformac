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
/// `divisor` is 1.0 for a normal single frame, or the running frame count when `source` is a
/// live-stack accumulation texture holding a running SUM rather than a single frame's values.
struct StretchParams {
    float blackPoint; // normalized 0...1
    float whitePoint; // normalized 0...1
    float divisor;
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
    float raw = source.read(gid).r / stretch.divisor;
    float display = applyStretch(raw, stretch);
    destination.write(float4(display, display, display, 1.0), gid);
}

/// Adds `source`'s per-pixel value into `accumulator` in place — the GPU running-sum step
/// behind Metal-accelerated live stacking. `accumulator` is `r32Float` for headroom well beyond
/// what hundreds of stacked 16-bit frames could sum to.
kernel void accumulateMono(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::read_write> accumulator [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= source.get_width() || gid.y >= source.get_height()) { return; }
    float newValue = source.read(gid).r;
    float current = accumulator.read(gid).r;
    accumulator.write(float4(current + newValue, 0, 0, 0), gid);
}

/// Zeroes a texture — used to reset the live-stack accumulator (freshly-allocated Metal textures
/// have undefined contents, unlike a Swift array literal-initialized to zero).
kernel void clearMono(
    texture2d<float, access::write> tex [[texture(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= tex.get_width() || gid.y >= tex.get_height()) { return; }
    tex.write(float4(0), gid);
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

    r /= stretch.divisor;
    g /= stretch.divisor;
    b /= stretch.divisor;
    float3 rgb = float3(applyStretch(r, stretch), applyStretch(g, stretch), applyStretch(b, stretch));
    destination.write(float4(rgb, 1.0), gid);
}

/// Bilateral filter — a classical (non-ML), edge-preserving denoiser: averages neighboring
/// pixels weighted by both spatial distance and intensity similarity, so it smooths flat noisy
/// regions (sky background) while leaving sharp edges (star points, planetary detail) largely
/// intact. Real-time per-frame noise suppression without requiring a trained model of any kind.
kernel void bilateralDenoise(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    constant float &spatialSigma [[buffer(0)]],
    constant float &rangeSigma [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= source.get_width() || gid.y >= source.get_height()) { return; }
    float center = source.read(gid).r;
    float sumWeight = 0;
    float sumValue = 0;
    const int radius = 2;
    for (int dy = -radius; dy <= radius; dy++) {
        for (int dx = -radius; dx <= radius; dx++) {
            int x = clamp(int(gid.x) + dx, 0, int(source.get_width()) - 1);
            int y = clamp(int(gid.y) + dy, 0, int(source.get_height()) - 1);
            float sample = source.read(uint2(x, y)).r;
            float spatialWeight = exp(-float(dx * dx + dy * dy) / (2 * spatialSigma * spatialSigma));
            float delta = sample - center;
            float rangeWeight = exp(-(delta * delta) / (2 * rangeSigma * rangeSigma));
            float w = spatialWeight * rangeWeight;
            sumWeight += w;
            sumValue += w * sample;
        }
    }
    destination.write(float4(sumValue / max(sumWeight, 1e-6), 0, 0, 0), gid);
}

/// One level of an à trous ("with holes") wavelet blur — the standard stationary wavelet
/// transform used by multi-scale sharpening tools like RegiStax: a B3-spline low-pass filter
/// applied with `spacing` gaps between taps (rather than shrinking the image, as a dyadic
/// pyramid would), so every scale stays pixel-aligned with the original for direct subtraction.
kernel void waveletBlur(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    constant int &spacing [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= source.get_width() || gid.y >= source.get_height()) { return; }
    constexpr float k[5] = {1.0 / 16, 4.0 / 16, 6.0 / 16, 4.0 / 16, 1.0 / 16};
    float sum = 0;
    for (int j = -2; j <= 2; j++) {
        for (int i = -2; i <= 2; i++) {
            int x = clamp(int(gid.x) + i * spacing, 0, int(source.get_width()) - 1);
            int y = clamp(int(gid.y) + j * spacing, 0, int(source.get_height()) - 1);
            sum += k[i + 2] * k[j + 2] * source.read(uint2(x, y)).r;
        }
    }
    destination.write(float4(sum, 0, 0, 0), gid);
}

/// Reconstructs a sharpened image from the original plus two wavelet detail layers (original
/// minus the first blur = fine detail; first blur minus second blur = mid detail), each boosted
/// by its own gain — the actual "sharpening" step, e.g. for Lunar craters or Jupiter's bands.
kernel void waveletCombine(
    texture2d<float, access::read> original [[texture(0)]],
    texture2d<float, access::read> blurLayer0 [[texture(1)]],
    texture2d<float, access::read> blurLayer1 [[texture(2)]],
    texture2d<float, access::write> destination [[texture(3)]],
    constant float &fineGain [[buffer(0)]],
    constant float &midGain [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= original.get_width() || gid.y >= original.get_height()) { return; }
    float orig = original.read(gid).r;
    float layer0 = blurLayer0.read(gid).r;
    float layer1 = blurLayer1.read(gid).r;
    float fineDetail = orig - layer0;
    float midDetail = layer0 - layer1;
    float sharpened = layer1 + midDetail * (1.0 + midGain) + fineDetail * (1.0 + fineGain);
    destination.write(float4(saturate(sharpened), 0, 0, 0), gid);
}

/// GPU per-frame sharpness scoring for the continuous-recording quality gate: computes the
/// energy of the discrete Laplacian (mean squared Laplacian; equivalent in spirit to
/// `SharpnessScorer`'s CPU variance-of-Laplacian, assuming the Laplacian's own mean is ~0 for a
/// natural image, which variance-of-Laplacian implicitly does too) as one partial sum per
/// threadgroup — summing on the CPU after readback avoids the 32-bit atomic overflow a single
/// global accumulator would risk on a multi-megapixel frame.
kernel void sharpnessPartialSums(
    texture2d<float, access::read> source [[texture(0)]],
    device float *partialSums [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 tid [[thread_position_in_threadgroup]],
    uint2 groupId [[threadgroup_position_in_grid]],
    uint2 threadsPerThreadgroup [[threads_per_threadgroup]],
    uint2 groupsPerGrid [[threadgroups_per_grid]],
    threadgroup atomic_uint *localSum [[threadgroup(0)]]
) {
    uint localIndex = tid.y * threadsPerThreadgroup.x + tid.x;
    if (localIndex == 0) {
        atomic_store_explicit(localSum, 0, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    float squaredLaplacian = 0;
    if (gid.x > 0 && gid.y > 0 && gid.x < source.get_width() - 1 && gid.y < source.get_height() - 1) {
        float center = source.read(gid).r;
        float up = source.read(uint2(gid.x, gid.y - 1)).r;
        float down = source.read(uint2(gid.x, gid.y + 1)).r;
        float left = source.read(uint2(gid.x - 1, gid.y)).r;
        float right = source.read(uint2(gid.x + 1, gid.y)).r;
        float laplacian = 4.0 * center - up - down - left - right;
        squaredLaplacian = laplacian * laplacian; // texture is normalized 0...1, so this is <= 16
    }
    // Fixed-point scale chosen so a full threadgroup (up to 256 threads) of worst-case values
    // (16.0 each) sums to ~4.1e8, safely under atomic_uint's ~4.29e9 ceiling.
    uint scaled = uint(squaredLaplacian * 1.0e5);
    atomic_fetch_add_explicit(localSum, scaled, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (localIndex == 0) {
        uint groupIndex = groupId.y * groupsPerGrid.x + groupId.x;
        uint groupSumFixed = atomic_load_explicit(localSum, memory_order_relaxed);
        partialSums[groupIndex] = float(groupSumFixed) / 1.0e5;
    }
}

/// Parallel histogram: each threadgroup accumulates into threadgroup memory, then atomically
/// adds into the 256-bucket device buffer. Replaces `HistogramComputer`'s CPU pass.
kernel void histogramReduce(
    texture2d<float, access::read> source [[texture(0)]],
    device atomic_uint *buckets [[buffer(0)]],
    constant float &divisor [[buffer(1)]],
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
        float value = source.read(gid).r / divisor;
        uint bucket = min(uint(saturate(value) * 255.0), 255u);
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
