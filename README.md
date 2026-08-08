# MacZWO

A native macOS astrophotography capture app built directly on the ZWO ASI Camera SDK — no ASCOM/INDI bridging layer. See `spec/MacZWO_ClaudeCode_Spec.md` for the original spec.

## Requirements

- Xcode 26+ (Swift 6), macOS 14.0+ deployment target.
- The Metal toolchain component (`xcodebuild -downloadComponent MetalToolchain`) — needed once, to compile `Shaders.metal`.

## Building

```
make build   # build into ./build
make test    # run the MacZWOTests unit test suite
make run     # build and launch MacZWO.app
make clean   # remove ./build
make open    # open the project in Xcode
```

(`make` alone runs `build`. See `make help` for the full list.) Or open `MacZWO.xcodeproj` in
Xcode and run/test normally (⌘R / ⌘U). The Makefile just wraps the equivalent `xcodebuild`
invocations with a pinned `-derivedDataPath ./build`, if you'd rather call those directly.

No camera required to build, run, or test — see "Try it without hardware" below.

## Project layout

- `Vendor/ZWO/` — vendored ZWO SDK: `include/ASICamera2.h` and a universal (arm64 + x86_64)
  `libASICamera2.dylib`, `lipo`'d together from the official SDK's `mac_arm64` and `mac`
  builds (`ASI_Camera_SDK/ASI_linux_mac_SDK_V1.41/lib/`) and ad-hoc re-signed. The dylib is
  linked and embedded into the app bundle (`Contents/Frameworks/`) via a Copy Files build phase.
- `MacZWO/Bridging/` — the C-to-Swift bridge (`ZWOSDK`, `ZWOError`, `ZWOCameraInfo`,
  `ZWOControlCaps`). No raw C struct or pointer crosses out of this layer.
- `MacZWO/Capture/` — `CaptureEngine` (an `actor` owning the `ASIGetVideoData` poll loop, off
  the main thread by construction), `FrameBuffer` (the preallocated poll buffer), and
  `TestPatternGenerator` (synthetic frames for the no-hardware debug path).
- `MacZWO/CameraManagement/` — `CameraManager`, the `@Observable` `@MainActor` view model.
- `MacZWO/Rendering/` — both render paths: `CGImageRenderer` + `Debayer` + `HistogramComputer`
  (CPU), and `MetalFrameRenderer` + `Shaders.metal` (GPU). `DisplayStretch` is the shared
  black/white-point model.
- `MacZWO/Views/` — SwiftUI.
- `MacZWOTests/` — unit tests for the pixel math (`Debayer`, `DisplayStretch`, `ZWOError`
  mapping) using Swift Testing.

## Try it without hardware

No physical ASI camera on hand? In the camera list sidebar, use **Simulate Mono** / **Simulate
Color** to feed a synthetic test pattern through the exact same debayer → histogram → render
pipeline a real camera would use. Toggle **Metal Renderer** in the toolbar to compare the CPU
(`CGImage`) and GPU (Metal compute shader) render paths side by side.

## Design decisions worth knowing about

- **App Sandbox is disabled** (`MacZWO/Resources/MacZWO.entitlements`). ZWO's SDK talks to the
  camera over raw USB in a way that doesn't reliably work under the sandboxed USB entitlement
  for arbitrary vendor devices. This app is meant to be distributed Developer ID–signed +
  notarized (outside the Mac App Store) — the same model ZWO's own ASIStudio uses. Hardened
  runtime is on, with `com.apple.security.cs.disable-library-validation` set so the embedded
  (non-Apple-signed) `libASICamera2.dylib` can load under it.
- **`vImageBayerToRGB` doesn't exist.** The original spec suggested it as the CPU debayer
  approach; there is no Bayer/demosaic API anywhere in the current Accelerate/vImage headers.
  `Debayer.swift` implements standard bilinear demosaicing by hand instead (verified against
  known-value test fixtures in `MacZWOTests/DebayerTests.swift`).
- **Deployment target is 14.0, not the spec's 13.0.** `@Observable` (used for `CameraManager`)
  requires macOS 14.

## Permissions

First connection to a USB ASI camera may prompt via System Settings → Privacy & Security. Keep
the camera connected when you grant the prompt. No other special entitlements are required
beyond what's already configured (see above).

## Status

Everything in the spec's four milestones is implemented (discovery, RAW8 preview, dynamic
controls, RAW16 + debayer + histogram), plus two upgrades beyond it:

- **GPU pass**: `Shaders.metal` does the Bayer debayer and black/white stretch as compute
  kernels; toggle "Metal Renderer" in the toolbar to switch the live preview between the CPU
  (`CGImage`) and GPU (Metal) paths at runtime.
- **Single-exposure capture**: `ASIStartExposure`/`ASIGetExpStatus`/`ASIGetDataAfterExp` for
  proper long deep-sky exposures (the video-poll loop stops for the duration; "Resume Live
  View" restarts it), in the Controls panel's "Single Exposure" section.
- **Focus assist**: an on-device, no-network "AI" building block — Vision's
  `VNDetectContoursRequest` picks out star-like point sources in the live preview, overlaid as
  circles with a star count + median size (smaller = sharper focus) readout. Toggle "Focus
  Assist" in the Controls panel.

All of the above has been verified without a physical camera attached: the app builds, launches,
and runs cleanly with zero cameras connected, the unit test suite passes (`MacZWOTests`,
13 tests covering the debayer math, the stretch LUT, and `ASI_ERROR_CODE` mapping), and the
"Simulate Mono/Color" debug path exercises the full pipeline end-to-end — debayer, histogram,
CPU and GPU rendering, single-exposure capture, and focus-assist star detection all run cleanly
against synthetic frames with no crashes or logged exceptions.

Real-hardware validation (does a real camera actually enumerate/stream/expose correctly) is
still outstanding and should be the first thing to check once a camera is available — nothing
here has touched actual ZWO USB hardware yet.
