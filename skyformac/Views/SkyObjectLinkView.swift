import SwiftUI

/// "The object info modal can be opened in other pages of the application where an object is
/// listed, like a captured session or Live Capture" — wraps a single object name (a
/// `Session.plannedObjects` entry) as a tappable link that opens the same detail sheet "What to
/// See" itself uses, resolved fresh via `SkyObjectResolver` from just the name and the given
/// location.
struct SkyObjectLinkView: View {
    let objectName: String
    var location: GeoLocation?
    @State private var isShowingDetail = false
    @State private var resolvedInfo: SkyObjectResolver.Info?
    @State private var didAttemptResolve = false

    var body: some View {
        Button(objectName) {
            resolvedInfo = SkyObjectResolver.resolve(objectName: objectName, location: location)
            didAttemptResolve = true
            isShowingDetail = true
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .underline()
        .sheet(isPresented: $isShowingDetail) {
            if let resolvedInfo {
                SkyVisibilityObjectDetailView(
                    title: resolvedInfo.title, subtitle: resolvedInfo.subtitle, symbolName: resolvedInfo.symbolName,
                    riseTime: resolvedInfo.riseTime, peakTime: resolvedInfo.peakTime, setTime: resolvedInfo.setTime,
                    skyCoordinates: resolvedInfo.skyCoordinates,
                    onDismiss: { isShowingDetail = false }
                )
            } else if didAttemptResolve {
                VStack(spacing: 12) {
                    Text("No catalog match for \"\(objectName)\".")
                        .foregroundStyle(.secondary)
                    Button("Close") { isShowingDetail = false }
                }
                .padding()
                .frame(width: 320, height: 140)
            }
        }
    }
}

/// A comma-separated planned-object list, each entry individually tappable — the multi-object
/// equivalent of `SkyObjectLinkView`, for the several places `Session.plannedObjects` renders as
/// one joined string today.
struct SkyObjectListLinkView: View {
    let objectNames: [String]
    var location: GeoLocation?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(objectNames.enumerated()), id: \.offset) { index, name in
                SkyObjectLinkView(objectName: name, location: location)
                if index < objectNames.count - 1 {
                    Text(",")
                }
            }
        }
    }
}
