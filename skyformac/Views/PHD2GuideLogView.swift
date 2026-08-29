import Charts
import SwiftUI
import UniformTypeIdentifiers

/// A standalone diagnostic for an *imported* PHD2 guide log — this app has no autoguiding loop of
/// its own to generate one from (see `ControlsPanelView`'s own doc comment on manual pulse-guiding
/// only), but plenty of users guide with PHD2 alongside it and have no easy way to see what their
/// guiding actually looked like afterward. Import a `.log` file, pick which guiding run within it
/// (a log can hold several), and see RMS/peak error, RA/Dec orthogonality, and a periodogram of
/// the RA error to spot worm-gear periodic error.
struct PHD2GuideLogView: View {
    @State private var isImporting = false
    @State private var sessions: [PHD2GuideLogSession] = []
    @State private var selectedSessionID: PHD2GuideLogSession.ID?
    @State private var errorMessage: String?

    private var selectedSession: PHD2GuideLogSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageSection(title: "Import") {
                    HStack {
                        Button("Import PHD2 Guide Log…") { isImporting = true }
                        if let errorMessage {
                            Text(errorMessage).font(.caption).foregroundStyle(.red)
                        }
                    }
                    if sessions.count > 1 {
                        Picker("Guiding Run", selection: $selectedSessionID) {
                            ForEach(sessions) { session in
                                Text(session.startedAt.map(Self.dateFormatter.string) ?? "Untitled run")
                                    .tag(Optional(session.id))
                            }
                        }
                    }
                }

                if let session = selectedSession {
                    let stats = PHD2GuideLogAnalyzer.stats(for: session)
                    PageSection(title: "Summary") {
                        LabeledContent("RMS RA", value: format(stats.rmsRA, unit: session.unitLabel))
                        LabeledContent("RMS Dec", value: format(stats.rmsDec, unit: session.unitLabel))
                        LabeledContent("RMS Total", value: format(stats.rmsTotal, unit: session.unitLabel))
                        LabeledContent("Peak RA", value: format(stats.peakRA, unit: session.unitLabel))
                        LabeledContent("Peak Dec", value: format(stats.peakDec, unit: session.unitLabel))
                        LabeledContent("RA/Dec Orthogonality", value: String(format: "%.2f", stats.orthogonality))
                        Text(orthogonalityNote(stats.orthogonality))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    PageSection(title: "Guide Error Over Time") {
                        Chart {
                            ForEach(session.frames, id: \.timeSeconds) { frame in
                                LineMark(x: .value("Time (s)", frame.timeSeconds), y: .value("RA", frame.raDistance))
                                    .foregroundStyle(by: .value("Axis", "RA"))
                            }
                            ForEach(session.frames, id: \.timeSeconds) { frame in
                                LineMark(x: .value("Time (s)", frame.timeSeconds), y: .value("Dec", frame.decDistance))
                                    .foregroundStyle(by: .value("Axis", "Dec"))
                            }
                        }
                        .frame(height: 200)
                    }

                    let periodogram = PHD2GuideLogAnalyzer.periodogram(
                        times: session.frames.map(\.timeSeconds), values: session.frames.map(\.raDistance)
                    )
                    if let dominant = periodogram.max(by: { $0.power < $1.power }) {
                        PageSection(title: "RA Periodogram") {
                            Chart(periodogram) { point in
                                LineMark(x: .value("Period (s)", point.periodSeconds), y: .value("Power", point.power))
                            }
                            .frame(height: 160)
                            Text("Dominant period: \(Int(dominant.periodSeconds))s — a real, repeating peak here (not just noise) usually points at worm-gear periodic error at that period.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if !sessions.isEmpty {
                    Text("Select a guiding run above.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Guiding Log")
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.text, .plainText, UTType(filenameExtension: "log") ?? .plainText]) { result in
            switch result {
            case .success(let url):
                importLog(from: url)
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    private func importLog(from url: URL) {
        errorMessage = nil
        let accessGranted = url.startAccessingSecurityScopedResource()
        defer { if accessGranted { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            errorMessage = "Couldn't read that file as text."
            return
        }
        let parsed = PHD2GuideLogParser.parse(text)
        guard !parsed.isEmpty else {
            errorMessage = "No guiding runs found in that file — is it a PHD2 guide log?"
            return
        }
        sessions = parsed
        selectedSessionID = parsed.last?.id
    }

    private func format(_ value: Double, unit: String) -> String {
        String(format: "%.2f %@", value, unit)
    }

    private func orthogonalityNote(_ value: Double) -> String {
        if abs(value) < 0.2 { return "Close to 0 — RA and Dec are guiding independently, as they should." }
        return "Farther from 0 than ideal — could point at a guide camera that isn't quite square to the mount's RA/Dec axes."
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
