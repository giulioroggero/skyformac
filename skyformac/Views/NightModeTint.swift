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
    @ViewBuilder
    func nightModeTint(_ cameraManager: CameraManager) -> some View {
        self.colorMultiply(cameraManager.isNightModeEnabled ? .red : .white)
    }
}
