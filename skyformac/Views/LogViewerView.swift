import AppKit
import SwiftUI

/// "skyformac → Show Log…" — every entry `AppLog` has captured this run (connection events,
/// errors, Ollama planning failures). Meant for grabbing what actually happened when reporting a
/// problem, not a full log viewer with levels/filtering — this app doesn't need that much.
struct LogViewerView: View {
    @Environment(\.dismiss) private var dismiss
    private var log: AppLog { AppLog.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Application Log").font(.headline)
                Spacer()
                Text("\(log.entries.count) line\(log.entries.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            if log.entries.isEmpty {
                ContentUnavailableView("Nothing Logged Yet", systemImage: "doc.text")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(log.entries) { entry in
                            Text(entry.formattedLine)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contextMenu {
                                    Button("Copy Line") { copy(entry.formattedLine) }
                                }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
            }

            Divider()

            HStack {
                Button("Clear", systemImage: "trash", role: .destructive) { log.clear() }
                Spacer()
                Button("Copy All", systemImage: "doc.on.doc") { copy(log.fullText) }
                    .disabled(log.entries.isEmpty)
                Button("Export…", systemImage: "square.and.arrow.up", action: exportLog)
                    .disabled(log.entries.isEmpty)
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 720, height: 520)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func exportLog() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "skyformac-log.txt"
        let text = log.fullText
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
