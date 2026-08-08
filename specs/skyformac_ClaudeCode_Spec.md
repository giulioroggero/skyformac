# Claude Code Specification: macOS Native ZWO Capture App

## 1. Project Overview
**Objective:** Build a macOS-native astrophotography capture application (similar to SharpCap) built exclusively around the ZWO ASI Camera SDK. The app will communicate natively with ZWO cameras over USB without requiring third-party bridging layers like ASCOM or INDI. 

**Target Platform:** macOS 13.0+ (Apple Silicon optimized).
**Development Environment:** Xcode 16+, Swift 6.

---

## 2. Technology Stack
*   **Core Language:** Swift 6 (with Objective-C Bridging for C APIs).
*   **UI Framework:** SwiftUI (for settings, histograms, and layout) + MetalKit (for high-performance raw frame rendering).
*   **Hardware Interface:** ZWO ASI SDK (`libASICamera2.dylib` and `ASICamera2.h`).
*   **Image Processing:** 
    *   `Accelerate` framework (`vImage`) for CPU-based debayering and scaling.
    *   `Metal` for GPU-accelerated histogram stretching and live stacking.

---

## 3. Architecture Guidelines

### 3.1. C-to-Swift Bridging Layer
*   **Objective:** Safely wrap the raw C-functions from `ASICamera2.h` into modern Swift.
*   **Implementation:**
    *   Create a `ZWOError` enum conforming to `Error` to map `ASI_ERROR_CODE` to Swift exceptions.
    *   Never expose raw C pointers (`UnsafeMutablePointer`) to the SwiftUI layer.
    *   Use an Objective-C bridging header (`App-Bridging-Header.h`) to expose the ZWO C-header.

### 3.2. Camera Management (State & Control)
*   **Objective:** Manage camera lifecycle (connect, disconnect, fetch parameters).
*   **Implementation:**
    *   Create a `CameraManager` class conforming to `@Observable` (or `ObservableObject`).
    *   Expose camera controls via published properties (e.g., `gain`, `exposureTime`, `binning`, `isCoolerOn`).
    *   Any writes to the camera settings (e.g., `ASISetControlValue`) must be handled safely, checking for `ASI_SUCCESS`.

### 3.3. The Capture Pipeline & Concurrency
*   **Objective:** Handle high-speed polling of video data without dropping frames or freezing the UI.
*   **Implementation:**
    *   **Strict Rule:** No `ASIGetVideoData` or `ASIStartVideoCapture` calls on the Main Thread.
    *   Use Swift Concurrency (e.g., an `Actor` named `CaptureEngine`) or a dedicated background `DispatchQueue(label: "com.app.zwocapture", qos: .userInteractive)`.
    *   **Buffer Management:** Pre-allocate a fixed-size `[UInt8]` or `UnsafeMutableRawBufferPointer` to hold the incoming frame to avoid re-allocating memory on every frame.

### 3.4. Rendering Pipeline
*   **Objective:** Display 8-bit or 16-bit monochrome/color data smoothly.
*   **Implementation:**
    *   Convert raw buffers into `CGImage`.
    *   For Mono cameras (RAW8): Use `CGColorSpaceCreateDeviceGray()`.
    *   For Color cameras (RAW16/RGB24): Implement a fast Debayer function (e.g., using `vImageBayerToRGB` from the Accelerate framework) before pushing to SwiftUI.

---

## 4. Development Phases / Milestones

### Milestone 1: SDK Integration & Discovery
*   [ ] Configure Xcode project with `libASICamera2.dylib`.
*   [ ] Set up Bridging Header.
*   [ ] Implement `ASIGetNumOfConnectedCameras` and populate a SwiftUI List/Dropdown of connected devices.
*   [ ] Read and display camera capabilities (Resolution, Pixel Size, Supported Binnings).

### Milestone 2: Basic Preview (Mono/8-bit)
*   [ ] Implement `ASIOpenCamera` and `ASIInitCamera`.
*   [ ] Set camera format to `ASI_IMG_RAW8`.
*   [ ] Spin up the background thread and implement `ASIGetVideoData`.
*   [ ] Render the byte array to a `CGImage` and display it in a SwiftUI `Image` view.

### Milestone 3: Core Camera Controls
*   [ ] Map `ASIGetNumOfControls` and `ASIGetControlCaps` to build dynamic SwiftUI sliders for available controls.
*   [ ] Implement Exposure slider (microseconds to seconds).
*   [ ] Implement Gain slider.
*   [ ] Implement Cooler control toggle and read target/current temperature.

### Milestone 4: Advanced Rendering & Color
*   [ ] Add support for `ASI_IMG_RAW16`.
*   [ ] Implement CPU-based debayering using `Accelerate` for color cameras.
*   [ ] Build a live Histogram view calculating black point and white point stretching.

---

## 5. Specific Directives for Claude Code
When generating code for this project, Claude MUST:
1.  **Strict Threading:** Never place blocking C-calls (`ASIGetVideoData`) in SwiftUI view modifiers or on the `@MainActor`.
2.  **Memory Safety:** Be explicit about buffer management. Use `Data(bytesNoCopy:...)` or `CGDataProvider` where applicable to prevent unnecessary memory copying of heavy image arrays.
3.  **Graceful Failures:** If a ZWO function returns `ASI_ERROR_CAMERA_REMOVED`, catch it, stop the capture thread, and notify the user interface immediately.
4.  **macOS Permissions:** Remember to remind the user to add USB or relevant hardware sandbox capabilities/entitlements in Xcode.
