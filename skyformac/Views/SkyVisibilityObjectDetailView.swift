import AppKit
import SwiftUI

/// The detail sheet behind tapping a "What to See" result — local facts (type, magnitude, rise/
/// peak/set times) always shown, plus an opt-in Wikipedia description/thumbnail
/// (`AppSettings.isOnlineObjectInfoEnabled`) and one-tap AstroBin/Reddit searches (a browser
/// hand-off, not a request this app makes itself, so those work regardless of that toggle).
struct SkyVisibilityObjectDetailView: View {
    let title: String
    let subtitle: String
    let symbolName: String
    let riseTime: Date?
    let peakTime: Date
    let setTime: Date?
    var onDismiss: () -> Void

    @State private var wikipediaSummary: WikipediaLookupService.Summary?
    @State private var wikipediaErrorMessage: String?
    @State private var isLoadingWikipedia = false
    @State private var thumbnailImage: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.title2.bold())
                Spacer()
                Button("Done", action: onDismiss).keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                            Image(systemName: symbolName).font(.title).foregroundStyle(.secondary)
                        }
                        .frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }

                    PageSection(title: "Tonight") {
                        LabeledContent("Rises") { Text(riseTime.map(Self.timeFormatter.string) ?? "Already up") }
                        LabeledContent("Peaks") { Text(Self.timeFormatter.string(from: peakTime)) }
                        LabeledContent("No Longer Visible") { Text(setTime.map(Self.timeFormatter.string) ?? "Still up at dawn") }
                    }

                    PageSection(title: "About") {
                        if !AppSettings.isOnlineObjectInfoEnabled {
                            Text("Enable \"Online Object Info\" in Settings › AI to see a Wikipedia description and photo here.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else if isLoadingWikipedia {
                            ProgressView()
                        } else if let wikipediaSummary {
                            if let thumbnailImage {
                                Image(nsImage: thumbnailImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxHeight: 220)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            Text(wikipediaSummary.extract).font(.callout)
                            if let pageURL = wikipediaSummary.pageURL {
                                Button("Open on Wikipedia…") { NSWorkspace.shared.open(pageURL) }
                            }
                        } else if let wikipediaErrorMessage {
                            Text(wikipediaErrorMessage).font(.callout).foregroundStyle(.secondary)
                        }
                    }

                    PageSection(title: "More") {
                        Button("Search on AstroBin…") { openAstroBinSearch() }
                        Button("Search r/astrophotography…") { openRedditSearch() }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 460, height: 560)
        .task { await loadWikipediaSummaryIfEnabled() }
    }

    private func loadWikipediaSummaryIfEnabled() async {
        guard AppSettings.isOnlineObjectInfoEnabled else { return }
        isLoadingWikipedia = true
        do {
            let summary = try await WikipediaLookupService.summary(for: title)
            wikipediaSummary = summary
            if let thumbnailURL = summary.thumbnailURL,
               let (data, _) = try? await URLSession.shared.data(from: thumbnailURL) {
                thumbnailImage = NSImage(data: data)
            }
        } catch WikipediaLookupService.LookupError.notFound {
            wikipediaErrorMessage = "No Wikipedia article found for \"\(title)\"."
        } catch {
            wikipediaErrorMessage = "Couldn't reach Wikipedia — check your network connection."
        }
        isLoadingWikipedia = false
    }

    private func openAstroBinSearch() {
        guard let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.astrobin.com/search/?q=\(encoded)")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func openRedditSearch() {
        guard let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.reddit.com/r/astrophotography/search/?q=\(encoded)&restrict_sr=1")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
