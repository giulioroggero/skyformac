# Specification: SkyForMac Planetary & Lunar Post-Processing Engine

## 1. Overview
The goal of this module is to provide a fast, Mac-native planetary lucky-imaging pipeline inside SkyForMac. It replaces complex multi-tool workflows (Siril/AutoStakkert) with an automated or semi-automated pipeline: Frame Ingestion -> Debayering -> Quality Ranking & Alignment -> Stacking -> Wavelet Sharpening -> Display/Export.

---

## 2. Technical Stack & Dependencies
* **Language:** Swift 6 / C++20 (via Objective-C++ bridge)
* **Frame Processing / Acceleration:** Apple Accelerate Framework (vImage / vDSP) or Metal compute shaders.
* **Computer Vision & Alignment:** OpenCV (C++ core) for DFT phase correlation and feature registration.
* **File I/O:** Support for `.fit`/`.fits` (CFITSIO / native parser), `.ser` (Planetary video), and frame image sequences (`.png`, `.tiff`).

---

## 3. Core Engine Pipeline Architecture

```
[ Input File (SER/FITS/AVI) ]
             │
             ▼
    [ 1. Frame Ingestion & Debayer ]  ── (RGGB / Bayer Matrix)
             │
             ▼
    [ 2. Feature ROI Selection ]      ── (Manual anchor or Auto-Centroid)
             │
             ▼
    [ 3. Registration & Quality Sorting ] ── (DFT / OpenCV Phase Correlation)
             │
             ▼
    [ 4. Frame Stacking Integration ] ── (Mean/Median + Best N% selection)
             │
             ▼
    [ 5. Post-Processing & Sharpening ] ── (Wavelet / Channel Alignment)
             │
             ▼
    [ Viewport Rendering (AutoStretch) ]
```

---

## 4. Stage Specifications

### Stage 1: Frame Ingestion & Color Debayering
* **Input:** Raw 8-bit or 16-bit monochrome image array (e.g., ASI678MC RGGB matrix).
* **Operation:** Apply fast bilinear or HQ linear debayering using `vImage` or OpenCV (`COLOR_BayerBG2RGB` / `COLOR_BayerRG2RGB`).
* **Output:** 32-bit floating-point per-channel RGB tensor normalized `[0.0, 1.0]`.

### Stage 2: Quality Analysis & Registration (1-Point / Anchor Box)
* **Quality Metric:** Calculate image sharpness for each frame $F_i$ using Laplacian variance or Tenengrad gradient magnitude:
  $$Q(F_i) = \text{Var}(\nabla^2 F_i)$$
* **Registration:** 
  * Calculate horizontal ($\Delta x$) and vertical ($\Delta y$) offsets relative to a reference frame (Frame 0 or highest-quality frame).
  * Use Phase Correlation (`cv::phaseCorrelate`) or template matching (`cv::matchTemplate`) within a user-defined or auto-detected Region of Interest (ROI).
* **Sorting:** Sort frame indices descending by $Q(F_i)$ score.

### Stage 3: Frame Stacking (Integration)
* **Parameters:** `cutoffPercentage` (e.g., top 10% to 30% of frames).
* **Operation:**
  1. Apply frame translation shifts ($\Delta x, \Delta y$) to shift registered frames into sub-pixel alignment.
  2. Compute frame-by-frame **Median** or **Trimmed Mean** integration over selected frame indices.
* **Output:** Stacked 32-bit float master RGB array.

### Stage 4: Planetary Wavelet Sharpening Engine
* **Algorithm:** Multi-scale *à trous* wavelet transform (2D B-spline scaling function).
* **Layers:** 4 to 5 resolution scales:
  * **Layer 1 (Fine detail):** Micro-texture, noise filtering.
  * **Layer 2–3 (Medium detail):** Crater rims, rilles, planetary bands.
  * **Layer 4+ (Low frequency):** High-level contrast.
* **UI Controls:** Slider parameters for `Gain` and `Denoise` per wavelet layer.

### Stage 5: Color Alignment & Histogram Stretch
* **RGB Channel Auto-Alignment:** Perform cross-correlation between R, G, B channels to fix atmospheric dispersion fringing.
* **Display Viewport:** Render 32-bit linear floating point stack into 8-bit display via MTKView (Metal) applying non-linear gamma curve or dynamic Autostretch:
  $$\text{Pixel}_{\text{out}} = \frac{\ln(1 + a \cdot \text{Pixel}_{\text{in}})}{\ln(1 + a)}$$

---

## 5. Proposed Swift API / Module Interface

```swift
public protocol PlanetaryProcessingEngine {
    /// Load raw frame sequence or SER file
    func loadSequence(from url: URL) async throws -> SequenceMetadata
    
    /// Register frames using a designated ROI rect
    func registerFrames(roi: CGRect?, progress: @escaping (Float) -> Void) async -> [FrameQualityScore]
    
    /// Stack top N percent of frames
    func stackFrames(keepBestPercent: Float) async -> MasterFrame
    
    /// Apply à trous wavelet sharpening
    func applyWavelets(layers: [WaveletLayerConfig], master: MasterFrame) -> CGImage
    
    /// Auto align RGB color channels
    func alignRGB(master: MasterFrame) -> MasterFrame
}
```

---

## 6. Implementation Roadmap for Claude Code

1. **Step 1: Scaffolding**
   * Create `PlanetaryEngine` Swift package/module under `SkyForMac/Modules/PlanetaryEngine`.
   * Implement input reader for single image sequences (FITS, TIFF) and `.ser` video containers.

2. **Step 2: Core Stacking Engine**
   * Implement frame sharpness scorer (`Tenengrad` / `Laplacian`).
   * Implement sub-pixel translation alignment (`cv::phaseCorrelate`).
   * Build background thread stacker for memory-efficient frame accumulation.

3. **Step 3: Post-Processing Wavelet Tool**
   * Implement 2D à trous wavelet decomposition using Apple `vDSP` convolution primitives for maximum Apple Silicon performance.
   * Expose real-time slider updates for fine and medium detail layers.

4. **Step 4: UI Integration**
   * Add a "Planetary Stacker" sidebar panel in SkyForMac containing frame preview, ROI selector box, stack slider ("Keep top X%"), and Wavelet controls.

