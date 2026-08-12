# Claude Code Specification: Core ML & Apple Neural Engine AI Features Pipeline

## 1. Overview & Architecture
**Target Application:** `skyformac` (macOS native capture software for ZWO cameras & Webcams).  
**Goal:** Integrate five Apple Neural Engine (ANE) and Vision framework AI features to enhance image quality, automate planetary frame selection, mask satellite trails, upscale planetary ROI crops, and track clouds/targets.

### Architecture Principle: Zero-Copy & ANE Offloading
All machine learning inferencing **MUST** run on the Apple Neural Engine (`MLComputeUnits.neuralEngine`) using `CVPixelBuffer` instances backed by `IOSurface`. The GPU handles Metal stretching and rendering, while the CPU manages event dispatching.

```
                               ┌──────────────────────────────────────────────┐
                               │       Incoming Camera Frame (CVPixelBuffer)  │
                               └──────────────────────┬───────────────────────┘
                                                      │
                       ┌──────────────────────────────┼──────────────────────────────┐
                       ▼                              ▼                              ▼
          ┌──────────────────────────┐   ┌──────────────────────────┐   ┌──────────────────────────┐
          │  1. Core ML Denoise /    │   │  2. Vision Quality Score │   │  3. Satellite Masking    │
          │  Super-Res (ANE)         │   │  (Lucky Imaging Filter)  │   │  (Segmentation Shader)   │
          └────────────┬─────────────┘   └────────────┬─────────────┘   └────────────┬─────────────┘
                       │                              │                              │
                       └──────────────────────────────┼──────────────────────────────┘
                                                      │
                                                      ▼
                               ┌──────────────────────────────────────────────┐
                               │  4. Metal GPU Stretch & Render Pipeline     │
                               └──────────────────────────────────────────────┘
```

---

## 2. Feature 1: Real-Time AI Denoising (Neural Engine Offload)

### 2.1. Technical Requirements
* **Model Format:** Core ML `.package` (Converted from PyTorch UNet / DnCNN using `coremltools`).
* **Input Tensor:** `CVPixelBuffer` (`32BGRA` or `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`), shape: `1 x 3 x H x W` (or float scale `0.0 ... 1.0`).
* **Output Tensor:** `CVPixelBuffer` containing denoised RGB channels.

### 2.2. Swift Implementation Engine (`AIDenoiseEngine.swift`)
```swift
import CoreML
import Vision
import CoreVideo

actor AIDenoiseEngine {
    private var visionModel: VNCoreMLModel?
    private var isProcessing = false

    init(modelUrl: URL) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .neuralEngine // Force execution on Apple Neural Engine
        
        let compiledModel = try MLModel(contentsOf: modelUrl, configuration: config)
        self.visionModel = try VNCoreMLModel(for: compiledModel)
    }

    func denoiseFrame(_ pixelBuffer: CVPixelBuffer) async throws -> CVPixelBuffer? {
        guard !isProcessing, let visionModel = visionModel else { return nil }
        isProcessing = true
        defer { isProcessing = false }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNCoreMLRequest(model: visionModel) { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let results = request.results as? [VNPixelBufferObservation],
                      let outputBuffer = results.first?.pixelBuffer else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: outputBuffer)
            }

            request.imageCropAndScaleOption = .scaleFit
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
```

---

## 3. Feature 2: AI Frame Quality Scoring ("Lucky Imaging")

### 3.1. Technical Requirements
* Evaluate incoming planetary/lunar frames in real time using edge gradients and spatial contrast.
* Drop bad frames before writing to disk or passing to live stackers.

### 3.2. Swift Quality Scoring Engine (`AILuckyFilter.swift`)
```swift
import Vision
import CoreVideo

final class AILuckyFilter: @unchecked Sendable {
    /// Computes a normalized sharpness score (0.0 to 100.0) using Vision Contour & Gradient Analysis
    func evaluateSharpness(of pixelBuffer: CVPixelBuffer) async -> Float {
        return await withCheckedContinuation { continuation in
            let request = VNCalculateImageAestheticsScoresRequest { request, _ in
                guard let observation = request.results?.first as? VNAestheticsScoresObservation else {
                    continuation.resume(returning: 0.0)
                    return
                }
                // Combine sharpness score and overall aesthetic score
                let score = (observation.sharpness * 70.0) + (observation.overallScore * 30.0)
                continuation.resume(returning: score)
            }

            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            try? handler.perform([request])
        }
    }
}
```

---

## 4. Feature 3: AI Satellite & Aircraft Trail Masking

### 4.1. Technical Requirements
* Detect straight, continuous high-intensity light streaks (Starlink, airplanes, meteors).
* Generate a 1-bit binary mask (`0` = streak, `1` = clean sky) and pass it to Metal to exclude contaminated pixels during Live Stacking.

### 4.2. Metal Streak Suppression Mask Kernel (`StreakMaskShader.metal`)
```metal
#include <metal_stdlib>
using namespace metal;

kernel void apply_streak_mask(
    texture2d<float, access::read>  inputFrame [[texture(0)]],
    texture2d<float, access::read>  streakMask [[texture(1)]],
    texture2d<float, access::write> maskedFrame [[texture(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= inputFrame.get_width() || gid.y >= inputFrame.get_height()) return;

    float4 color = inputFrame.read(gid);
    float maskValue = streakMask.read(gid).r; // 1.0 = Keep, 0.0 = Mask out

    // Replace streak pixels with zero or interpolate background
    float4 cleanedColor = color * maskValue;
    maskedFrame.write(cleanedColor, gid);
}
```

---

## 5. Feature 4: AI Super-Resolution for Planetary Crops

### 5.1. Technical Requirements
* Upscale small ROI frames (e.g., $320 	imes 320$ planetary crop at 200 FPS) $4	imes$ to $1280 	imes 1280$ for sharp preview display.
* Model: Lightweight Real-ESRGAN distilled for ANE execution.

### 5.2. Swift Super-Resolution Pipeline (`AISuperResolutionEngine.swift`)
```swift
import CoreML
import CoreVideo

actor AISuperResolutionEngine {
    private let model: MLModel?

    init(compiledModelUrl: URL) {
        let config = MLModelConfiguration()
        config.computeUnits = .neuralEngine
        self.model = try? MLModel(contentsOf: compiledModelUrl, configuration: config)
    }

    func upscale4x(pixelBuffer: CVPixelBuffer) throws -> CVPixelBuffer? {
        guard let model = model else { return nil }
        
        // Wrap input pixel buffer into CoreML Feature Provider
        let inputFeatures = try MLDictionaryFeatureProvider(dictionary: ["input_image": pixelBuffer])
        let prediction = try model.prediction(from: inputFeatures)
        
        if let outputFeature = prediction.featureValue(for: "output_image"),
           let outputPixelBuffer = outputFeature.imageBufferValue {
            return outputPixelBuffer
        }
        
        return nil
    }
}
```

---

## 6. Feature 5: Intelligent Target & Cloud Tracking

### 6.1. Technical Requirements
* Detect sudden overall contrast and intensity drops indicative of incoming cloud cover.
* Automatically pause active exposure sequences and send a native macOS system notification.

### 6.2. Cloud & Drift Sentinel (`CloudSentinelEngine.swift`)
```swift
import Vision
import UserNotifications

final class CloudSentinelEngine: @unchecked Sendable {
    private var baselineLuminance: Float?
    var onCloudDetected: (@Sendable () -> Void)?

    func analyzeFrameForClouds(pixelBuffer: CVPixelBuffer) {
        let request = VNCalculateImageAestheticsScoresRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        
        try? handler.perform([request])
        
        // Evaluate average frame luminance via Accelerate vImage or Core Image statistics
        let currentLuminance = calculateMeanLuminance(pixelBuffer)
        
        if let baseline = baselineLuminance {
            let dropPercentage = (baseline - currentLuminance) / baseline
            
            // If light drops more than 60% suddenly, trigger Cloud Alert
            if dropPercentage > 0.60 {
                onCloudDetected?()
                sendSystemAlert(title: "Cloud Interruption", body: "Exposure paused due to dense cloud cover.")
            }
        } else {
            baselineLuminance = currentLuminance
        }
    }

    private func calculateMeanLuminance(_ pixelBuffer: CVPixelBuffer) -> Float {
        // CoreVideo / Accelerate vImage mean luminance computation
        return 0.5 // Placeholder value
    }

    private func sendSystemAlert(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
```

---

## 7. UI Controls & State Contract (`AIPipelineSettings.swift`)

Add a collapsible **AI Suite** section to the right-side control inspector in SwiftUI:

```
┌────────────────────────────────────────────────────────┐
│ ▼ AI & Machine Learning Suite              [On / Off] │
├────────────────────────────────────────────────────────┤
│ [✓] Neural Engine AI Denoise                           │
│ Model Mode:   [ Compact UNet (Low Power)    ▼ ]         │
│                                                        │
│ [✓] Lucky Imaging (Quality Filter)                     │
│ Drop Threshold [ ──────●─────── ] Top 25% Frames Only  │
│ Live Score:    78.4 / 100                              │
│                                                        │
│ [✓] Satellite & Aircraft Trail Masking                 │
│ Action:        [ Mask Out Streak Pixels      ▼ ]       │
│                                                        │
│ [✓] Planetary AI Super-Resolution (4x)                 │
│ Output Crop:   1280 x 1280 (Original: 320 x 320)         │
│                                                        │
│ [✓] Cloud Cover & Cable Drift Sentinel                 │
│ Status:        [ Sky Clear • Baseline Lock ]           │
└────────────────────────────────────────────────────────┘
```

### 7.1. Swift Observable State Model
```swift
import SwiftUI

@Observable
final class AIPipelineSettings {
    // Feature Toggles
    var isAIDenoiseEnabled: Bool = false
    var isLuckyImagingEnabled: Bool = false
    var isStreakMaskingEnabled: Bool = true
    var isSuperResolutionEnabled: Bool = false
    var isCloudSentinelEnabled: Bool = true
    
    // Config Parameters
    var luckyImagingThreshold: Float = 0.75 // Keep top 25% best frames
    var currentFrameQualityScore: Float = 0.0
    var denoiseModelSelection: DenoiseModel = .compact
    
    enum DenoiseModel: String, CaseIterable, Identifiable {
        case compact = "Compact UNet (Fast)"
        case deep = "Deep Astrophoto Net"
        var id: String { rawValue }
    }
}
```

---

## 8. Directives for Claude Code

1. **Hardware Specifics:** Explicitly configure all `MLModelConfiguration()` instances with `.computeUnits = .neuralEngine` to prevent GPU frame contention.
2. **Zero Allocation:** Pre-allocate `CVPixelBuffer` pools and `VNImageRequestHandler` wrappers. Do not create new allocation buffers inside the 60 FPS live frame delegate loop.
3. **Graceful Fallbacks:** If a custom Core ML `.package` file is missing, automatically fall back to Metal Performance Shaders (Bilateral filter).
4. **Thread Isolation:** Place all AI model inferencing routines inside Swift `actor` instances to maintain strict isolation from the `@MainActor`.

---

## 9. Implementation Notes (deviations from the above, as built)

Per `specs/README.md`'s "update the spec to match what was actually built" — where the shipped
implementation diverges from sections 1-8 above, and why.

1. **Features 1 (AI Denoise) and 4 (Super-Resolution) are not implemented — directive 3's own
   fallback *is* the real feature.** Both need a real trained Core ML model file (a UNet/DnCNN
   distilled for denoising; a distilled Real-ESRGAN for 4x upscaling) that this repo doesn't have
   and can't produce from a feature request — there's no training data, no GPU training run, and
   a `.package` full of random/uninitialized weights wouldn't denoise or upscale anything, it
   would just be expensive noise. This is the same wall `docs/design-notes.md` already documents
   once for the pre-existing "Apple Neural Engine AI Denoising" feature: it ships as a classical
   bilateral filter (`isDenoisingEnabled`) precisely because a real model can't be fabricated.
   Directive 3 already asks for exactly that fallback when a model file is missing — so rather
   than write `AIDenoiseEngine`/`AISuperResolutionEngine` classes whose `init` always takes the
   fallback path (dead code that never has a model to load), Feature 1 is simply the existing
   `isDenoisingEnabled` bilateral filter, and Feature 4 has no substitute shipped (the "AI Suite"
   panel says so directly, alongside pointing at Feature 1's real equivalent).
2. **Feature 2 (Lucky Imaging quality scoring) doesn't use `VNCalculateImageAestheticsScoresRequest`
   /`VNAestheticsScoresObservation`.** Unlike `VNDetectContoursRequest` (used elsewhere in this
   codebase and confirmed real by every build), this API's existence, minimum OS version, and
   exact properties (`sharpness`, `overallScore`) couldn't be verified in this environment — and
   guessing at an unverified Vision API is exactly the `vImageBayerToRGB` mistake
   `docs/design-notes.md` already warns against repeating. The app already had a real, tested
   equivalent doing the same job for the same feature: `SharpnessScorer`'s Laplacian-variance
   scoring, already driving `LuckyImagingSession`'s "keep the sharpest fraction" behavior. The
   only new work was surfacing it live (`CameraManager.currentFrameQualityScore`), normalized
   against the sharpest frame *this session has actually measured* rather than a fabricated fixed
   0-100 scale, since Laplacian variance has no fixed ceiling to calibrate one against.
3. **Feature 3 (streak masking) now masks the GPU accumulate path too — later closed, not still
   open.** The concern above (masking specific pixels in specific frames needs a *per-pixel*
   count, not `accumulateMono`'s one shared scalar) was real, but the fix avoided the "thread a
   second accumulator through every downstream kernel" cost it worried about: a masked frame
   accumulates into a *separate* `(sum, count)` texture pair via a new `accumulateMonoMasked`
   kernel, then a new `normalizeMaskedAccumulator` kernel collapses that pair into a true
   per-pixel average written into the *existing* `accumulationTexture` — so `stretchMono`/
   `debayerAndStretch`/`histogramReduce` never need to know masking happened at all; they just
   read `accumulationTexture` with `divisor = 1.0`, exactly as if it were one already-averaged
   frame. Two new kernels instead of retrofitting the existing ones. The Metal `apply_streak_mask`
   kernel in section 4.2 above was never actually built as written (it replaces masked pixels with
   zero, which — as this note originally pointed out — would darken a pixel's average instead of
   excluding it from the frames it didn't appear in); `accumulateMonoMasked`/
   `normalizeMaskedAccumulator` in `Shaders.metal` are what actually shipped, matching
   `LiveStacker.add(_:mask:)`'s CPU semantics exactly (skip, don't zero) rather than section 4.2's
   design. Masking takes priority over the (separately-added, GPU-only) drift-reduction live-stack
   alignment when both are enabled at once, since combining per-pixel masking with sub-pixel
   shift-sampling would need a third kernel variant for a combination that's rare in practice.
4. **No standalone `AIPipelineSettings.swift`/`AIDenoiseEngine.swift`/etc. files.** The two real
   features (streak masking, cloud sentinel) were added directly onto `CameraManager` and a small
   `CloudDriftSentinel` tracker class, matching how every other capture-pipeline feature in this
   app is already organized (compare `isPlanetaryTrackingEnabled`/`PlanetTracker`,
   `isDenoisingEnabled`) — introducing a second parallel settings object and a family of mostly-
   empty "engine" classes for two boolean toggles and one tracker would fragment state that's
   already naturally owned by `CameraManager` for no behavioral benefit. (Contrast this with
   `specs/skyformac_GPU_Live_Controls_Spec.md`'s `GPUControlSettings`, which *did* get a dedicated
   object — that feature has 7 tightly-coupled numeric parameters with real cross-field guardrails,
   which is a genuinely different shape of state.)
5. **Feature 5 (Cloud Sentinel) reuses `AllSkyAnalyzer`'s existing detection math (`isCloudOrLightAlert`)
   and baseline-update behavior exactly**, applied to the main ZWO/webcam pipeline instead of only
   the secondary All-Sky monitor camera — real code reuse instead of re-deriving the same
   brightness-ratio logic a second time. "Pause active exposure sequences" is implemented as
   stopping active continuous disk recording (`stopRecording()`) specifically — a single long
   `ASIStartExposure` exposure already in flight is a synchronous SDK call with no clean
   cancellation hook to add here without a larger change to `CaptureEngine`.
