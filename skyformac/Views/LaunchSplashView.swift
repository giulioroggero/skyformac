import AppKit
import SwiftUI

/// Shown for a short fixed stretch right after launch, covering `RootView` while it (and
/// `CameraManager`'s own synchronous startup work — reading every project's JSON, scanning for
/// connected cameras) settles in. Real app launch here is fast enough that there's rarely
/// anything to actually wait on by the time SwiftUI gets to render a first frame — this exists for
/// the same reason plenty of native Mac apps still show a brief splash regardless: a blank window
/// snapping straight to a fully-populated Home page reads as jarring/unfinished, where a short,
/// branded pause reads as intentional. `RootView` owns showing/dismissing this.
struct LaunchSplashView: View {
    /// Cycles independently of `factIndex` below, on a shorter interval — reads more like real
    /// progress ("first the projects, then the cameras...") than a single static "Loading…".
    @State private var statusIndex = 0
    @State private var factIndex = Int.random(in: 0..<observingFacts.count)

    private static let statusMessages = [
        "Loading your projects…",
        "Scanning for connected cameras…",
        "Checking equipment presets…",
        "Almost ready…",
    ]

    /// Short, real, citable facts about common visual/imaging targets — "nice sentences about the
    /// objects to observe," not generic loading-screen filler. One is picked at random to start
    /// (so a quick relaunch doesn't always show the same one first) and they cycle from there.
    private static let observingFacts = [
        "Saturn's rings are made almost entirely of water ice, with particles ranging from dust grains to boulders.",
        "The Orion Nebula (M42) is bright enough to see with the naked eye, and is one of the closest star-forming regions to Earth.",
        "The Andromeda Galaxy (M31) is about 2.5 million light-years away — the most distant thing most people ever see unaided.",
        "Jupiter's Great Red Spot is a storm wider than Earth that's been raging for at least 150 years.",
        "Albireo, a favorite double star, splits into a striking gold-and-blue pair even in a small telescope.",
        "The Moon's terminator — the line between day and night — is where lunar craters and mountains cast their longest, sharpest shadows.",
        "The Pleiades (M45) star cluster is young, hot, and still wrapped in faint wisps of the reflection nebula it formed from.",
        "The Ring Nebula (M57) is the glowing shell of gas a Sun-like star sheds near the end of its life.",
        "Mars can look almost featureless through a scope most of the year — surface detail only sharpens up near opposition.",
        "Venus goes through phases just like the Moon, since we watch it lit by the Sun from different angles.",
        "M82, the Cigar Galaxy, is undergoing a burst of star formation ten times faster than the Milky Way's.",
        "A camera's own sensor can reveal star colors the eye can barely perceive — cool orange giants, hot blue supergiants.",
    ]

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage())
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .shadow(radius: 8)
            Text("Skyformac")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
            ProgressView()
                .controlSize(.small)
                .padding(.top, 4)
            Text(Self.statusMessages[statusIndex])
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .id(statusIndex)
            Spacer()
            Text(Self.observingFacts[factIndex])
                .font(.callout)
                .italic()
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
                .contentTransition(.opacity)
                .id(factIndex)
                .padding(.bottom, 36)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .task { await cycleStatus() }
        .task { await cycleFacts() }
    }

    /// A little faster than the facts below — several status lines fit inside the splash's total
    /// on-screen time, so it reads as "working through steps" rather than one message the whole
    /// time.
    private func cycleStatus() async {
        while !Task.isCancelled, statusIndex < Self.statusMessages.count - 1 {
            try? await Task.sleep(for: .seconds(0.6))
            guard !Task.isCancelled else { return }
            withAnimation { statusIndex += 1 }
        }
    }

    private func cycleFacts() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled else { return }
            withAnimation { factIndex = (factIndex + 1) % Self.observingFacts.count }
        }
    }
}
