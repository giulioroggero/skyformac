# Claude Code Specification: GPU-Accelerated Live Controls & Low-Light Denoising Pipeline

## 1. Overview & Objective
**Target Application:** `skyformac` (macOS native capture app for ZWO ASI cameras & Webcams).
**Goal:** Implement a real-time, low-latency Metal GPU processing pipeline to eliminate low-light sensor noise, prevent highlight blowing/posterization, and provide non-linear image stretching. 

This spec replaces raw linear White Point/Black Point clipping with three GPU-driven stages:
1. **Temporal Frame Accumulator Shader** (Live Noise Reduction via Moving Average).
2. **Metal Performance Shaders (MPS) Bilateral Filter** (Spatial Edge-Preserving Denoising).
3. **Arcsinh Non-Linear Stretch Shader** (Dynamic Range Expansion without clipping highlights).

---

## 2. Technology Stack
* **Language:** Swift 6 + Metal Shading Language (MSL C++17).
* **Frameworks:** `Metal`, `MetalPerformanceShaders` (MPS), `CoreVideo` (`CVMetalTextureCache`), `SwiftUI`.
* **Execution Target:** Apple Silicon Unified Memory Architecture (M-Series GPUs).

---

## 3. Pipeline Execution Flow

Incoming camera buffers (`CMSampleBuffer` or ZWO RAW bytes) must pass through a 4-stage non-blocking GPU compute pipeline before being rendered in the `MTKView`.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ 1. Raw Camera Frame (Zero-Copy CVMetalTexture via CVMetalTextureCache)      │
└─────────────────────────────────────┬───────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ 2. Stage 1: GPU Temporal Accumulator Kernel (Moving Average Noise Reduct)    │
│    Accumulator Equation: A_n = (1 - α) * A_{n-1} + α * InputFrame           │
└─────────────────────────────────────┬───────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ 3. Stage 2: MPS Bilateral Denoise Filter (Spatial Noise Smoothing)          │
│    sigmaSpace: Spatial Blur Radius | sigmaRange: Edge Preservation Threshold │
└─────────────────────────────────────┬───────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ 4. Stage 3: Arcsinh Non-Linear Stretch Shader (Highlight-Safe Contrast Boost)│
│    Equation: I_out = arcsinh(I_in * S) / arcsinh(S)                         │
└─────────────────────────────────────┬───────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ 5. Display Output (MTKView / SwiftUI Render Layer)                          │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 4. GPU Shaders & Metal Code Implementation

### 4.1. Stage 1: Temporal Frame Accumulator Shader (`TemporalAccumulator.metal`)
Cancels random sensor thermal noise by blending sequential frames in GPU memory.

```metal
#include <metal_stdlib>
using namespace metal;

kernel void temporal_accumulator(
    texture2d<float, access::read>  currentFrame [[texture(0)]],
    texture2d<float, access::read>  previousAccumulator [[texture(1)]],
    texture2d<float, access::write> outputAccumulator [[texture(2)]],
    constant float &alpha [[buffer(0)]], // Blend factor (e.g., 0.1 for smooth, 1.0 for instant)
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= currentFrame.get_width() || gid.y >= currentFrame.get_height()) return;

    float4 current = currentFrame.read(gid);
    float4 previous = previousAccumulator.read(gid);

    // Exponential Moving Average
    float4 blended = mix(previous, current, alpha);

    outputAccumulator.write(blended, gid);
}
```

### 4.2. Stage 2: Spatial Edge-Preserving Denoise (Swift / MPS)
Uses native Apple silicon hardware acceleration to smooth background color blotches while preserving facial features and star points.

```swift
import Metal
import MetalPerformanceShaders

final class SpatialDenoiseStage {
    private let device: MTLDevice

    init(device: MTLDevice) {
        self.device = device
    }

    func encode(
        commandBuffer: MTLCommandBuffer,
        sourceTexture: MTLTexture,
        destinationTexture: MTLTexture,
        spatialSigma: Float, // Range: 1.0 ... 10.0
        rangeSigma: Float    // Range: 0.05 ... 0.5
    ) {
        let bilateral = MPSImageBilateralScale(
            device: device,
            sigmaSpace: spatialSigma,
            sigmaRange: rangeSigma
        )
        bilateral.encode(
            commandBuffer: commandBuffer,
            sourceTexture: sourceTexture,
            destinationTexture: destinationTexture
        )
    }
}
```

### 4.3. Stage 3: Arcsinh Non-Linear Stretch Shader (`ArcsinhStretch.metal`)
Replaces linear clipping (white point = 1%) to smoothly boost dark areas without blowing out bright highlights.

$$	ext{Pixel}_{	ext{out}} = rac{\operatorname{arcsinh}((	ext{Pixel}_{	ext{in}} - 	ext{BlackPoint}) \cdot S)}{\operatorname{arcsinh}(S)}$$

```metal
#include <metal_stdlib>
using namespace metal;

fragment float4 arcsinh_stretch_fragment(
    float4 position [[position]],
    float2 texCoord [[user(locn0)]],
    texture2d<float> colorTexture [[texture(0)]],
    constant float &stretchIntensity [[buffer(0)]], // S (e.g. 1.0 to 500.0)
    constant float &blackPoint [[buffer(1)]],       // Offset (0.0 to 0.5)
    constant float &whitePoint [[buffer(2)]]        // Scale Cap (0.5 to 1.0)
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    float4 rawColor = colorTexture.sample(textureSampler, texCoord);

    // 1. Subtract Black Point floor
    float3 normalized = max(rawColor.rgb - float3(blackPoint), float3(0.0));
    normalized /= max(whitePoint - blackPoint, 0.001);

    // 2. Apply non-linear inverse hyperbolic sine stretch
    float3 stretched;
    if (stretchIntensity > 1.0) {
        stretched = asinh(normalized * stretchIntensity) / asinh(stretchIntensity);
    } else {
        stretched = normalized;
    }

    return float4(saturate(stretched), rawColor.a);
}
```

---

## 5. UI Live Control Panel Specs (`LiveGPUControlsView.swift`)

Add a collapsible **Live GPU Controls** section in the right sidebar of `skyformac`:

```
┌────────────────────────────────────────────────────────┐
│ ▼ Live GPU Enhancement Controls             [On / Off] │
├────────────────────────────────────────────────────────┤
│ Temporal Denoise (Live Stacking)                       │
│ Smoothness [ ───●────────── ] α = 0.15                │
│                                                        │
│ Spatial Denoise (Bilateral MPS)                        │
│ Radius     [ ──────●─────── ] 3.5 px                   │
│ Range      [ ────●───────── ] 0.12                     │
│                                                        │
│ Non-Linear Contrast (Arcsinh Stretch)                  │
│ Boost      [ ───────●────── ] 25.0x                    │
│ Black Pt   [ ●───────────── ] 0.02                     │
│ White Pt   [ ─────────────● ] 0.98                     │
│                                                        │
│ [ Auto-Stretch Safety Lock ]                           │
└────────────────────────────────────────────────────────┘
```

### 5.1. Controls State Contract
```swift
@Observable
final class GPUControlSettings {
    var isEnabled: Bool = true
    
    // Stage 1: Temporal
    var temporalAlpha: Float = 0.15 // 0.01 (heavy stack) to 1.0 (instant/no stack)
    
    // Stage 2: Bilateral MPS
    var spatialSigma: Float = 3.5   // 1.0 to 10.0
    var rangeSigma: Float = 0.12    // 0.01 to 0.50
    
    // Stage 3: Arcsinh Stretch
    var stretchIntensity: Float = 25.0 // 1.0 (linear) to 200.0 (extreme boost)
    var blackPoint: Float = 0.02      // 0.0 to 0.4
    var whitePoint: Float = 0.98      // 0.5 to 1.0
    
    /// Auto-calculates optimal black/white points based on current frame histogram
    func autoStretch() {
        // Sets blackPoint to 1st percentile and stretchIntensity dynamically
    }
}
```

---

## 6. Safety Guardrails & Validation Logic

1. **Safety Lock on Histogram Sliders:**
   * Enforce `whitePoint >= blackPoint + 0.05` programmatically.
   * Disallow setting `whitePoint < 0.10` to prevent blowing out white noise into giant bright color artifacts.
2. **Exposure Limits Safeguard:**
   * When operating built-in webcams or Continuity Cameras, restrict minimum exposure time slider to **$1000\,\mu	ext{s}$ ($1\,	ext{ms}$)**.
   * Highlight a warning badge if exposure time $< 10000\,\mu	ext{s}$ in dark ambient conditions.
3. **Texture Recycling & Zero Allocation:**
   * Re-use a fixed pool of 3 `MTLTexture` instances (Input, Accumulator, Output) during execution.
   * **Never** allocate new `MTLTexture` objects inside the live video frame callback loop (`captureOutput`).

---

## 7. Implementation Directives for Claude Code

1. Implement `TemporalAccumulator.metal` and `ArcsinhStretch.metal` in the project's shaders folder.
2. Build a central `GPUPipelineManager` class executing the command queue off the Main Actor.
3. Wire the `LiveGPUControlsView` controls directly to the `GPUControlSettings` state model.
4. Verify zero memory growth under Xcode Instruments (Allocations/Metal System Trace) during 60 FPS live streaming.
