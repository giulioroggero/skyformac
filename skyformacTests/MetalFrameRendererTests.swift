import CoreGraphics
import Testing
@testable import skyformac

struct MetalFrameRendererTests {
    /// A 16:9 texture (webcam/iPhone-shaped) in a boxier 4:3-ish drawable — the exact mismatch
    /// that made the un-viewported GPU draw stretch webcam/iPhone frames (see
    /// `docs/design-notes.md`). The texture is proportionally *wider* than the drawable, so it
    /// fits by width (full drawable width) and gets bars top/bottom (letterboxed).
    @Test func letterboxesWideTextureInNarrowerDrawable() {
        let viewport = MetalFrameRenderer.letterboxViewport(
            textureWidth: 1920, textureHeight: 1080, drawableSize: CGSize(width: 800, height: 600)
        )
        #expect(viewport.width == 800)
        let expectedHeight = 800.0 * (1080.0 / 1920.0)
        #expect(abs(viewport.height - expectedHeight) < 0.001)
        #expect(abs(viewport.originY - (600 - expectedHeight) / 2) < 0.001)
        #expect(viewport.originX == 0)
    }

    /// A 4:3 texture in a wider 16:9 drawable — the opposite mismatch. The texture is
    /// proportionally *narrower* than the drawable, so it fits by height (full drawable height)
    /// and gets bars left/right (pillarboxed).
    @Test func pillarboxesNarrowTextureInWiderDrawable() {
        let viewport = MetalFrameRenderer.letterboxViewport(
            textureWidth: 1280, textureHeight: 960, drawableSize: CGSize(width: 1920, height: 1080)
        )
        #expect(viewport.height == 1080)
        let expectedWidth = 1080.0 * (1280.0 / 960.0)
        #expect(abs(viewport.width - expectedWidth) < 0.001)
        #expect(abs(viewport.originX - (1920 - expectedWidth) / 2) < 0.001)
        #expect(viewport.originY == 0)
    }

    /// Matching aspect ratios (a ZWO sensor that happens to actually be 4:3, in a 4:3 drawable)
    /// should fill the drawable exactly, with no bars at all.
    @Test func exactAspectRatioMatchFillsDrawable() {
        let viewport = MetalFrameRenderer.letterboxViewport(
            textureWidth: 1280, textureHeight: 960, drawableSize: CGSize(width: 640, height: 480)
        )
        #expect(viewport.width == 640)
        #expect(viewport.height == 480)
        #expect(viewport.originX == 0)
        #expect(viewport.originY == 0)
    }

    /// Degenerate input (no texture uploaded yet) falls back to filling the drawable rather than
    /// producing a zero-size or NaN viewport.
    @Test func degenerateTextureSizeFallsBackToFullDrawable() {
        let viewport = MetalFrameRenderer.letterboxViewport(
            textureWidth: 0, textureHeight: 0, drawableSize: CGSize(width: 800, height: 600)
        )
        #expect(viewport.width == 800)
        #expect(viewport.height == 600)
    }
}
