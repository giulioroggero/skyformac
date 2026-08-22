import SwiftUI

extension View {
    /// The shared red-tint-when-Night-Mode-is-on modifier — every top-level page/window/sheet in
    /// the app should apply this to its own root content so Night Mode actually covers the whole
    /// UI, not just whichever views happened to add it individually (`ContentView`'s sidebar/
    /// Controls panel and `PreviewView`'s own overlay chrome did this piecemeal, which is how the
    /// toolbar, detached panels, and every sheet ended up left out).
    ///
    /// Never apply this over the live camera image itself — see `PreviewView.imageNightTint`'s
    /// doc comment for why the image gets its own independent, opt-in toggle instead of
    /// inheriting this one.
    ///
    /// Only actually applies `.colorMultiply` when Night Mode is on — even the `.white` "no-op"
    /// value forces SwiftUI to render its content through an offscreen compositing group, which
    /// isn't free (see `PreviewView.tintedPreview`'s identical fix for the live image itself) and,
    /// applied to a `List`/sidebar or toolbar item, defeats macOS's native vibrancy/material
    /// rendering there — the sidebar's own background material fell back to a flat, non-adaptive
    /// gray instead of blending with the window behind it, while `Text`'s semantic (vibrancy-
    /// aware) foreground colors still rendered as if vibrancy were active, i.e. too light/washed-
    /// out against that now-flatter background: "the left bar isn't full dark, the camera name
    /// [and breadcrumb] are white [and hard to read]." With Night Mode off — the common case —
    /// skipping the modifier entirely restores the normal system materials.
    @ViewBuilder
    func nightModeTint(_ cameraManager: CameraManager) -> some View {
        if cameraManager.isNightModeEnabled {
            self.colorMultiply(.red)
        } else {
            self
        }
    }
}
