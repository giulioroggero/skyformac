import SwiftUI

/// "A chat on the right bar of all pages" — a `.sheet`-free sidebar embedded by `RootView`
/// alongside whichever page is currently showing (the Projects browser or the live camera view),
/// so it's the same one panel/conversation regardless of where the user is, not a separate chat
/// per page. Any proposed change (`CameraManager.assistantPendingAction`) always shows its own
/// Approve/Reject card rather than being applied the moment the model suggests it.
struct AssistantChatPanel: View {
    var cameraManager: CameraManager
    /// `true` when hosted inside `AssistantChatPanelController`'s floating `NSPanel` — hides the
    /// Minimize/Detach/Close controls that only make sense for the embedded sidebar, and shows a
    /// "Dock" button instead.
    var isDetachedWindow: Bool = false

    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if cameraManager.assistantMessages.isEmpty {
                            Text("Ask about your projects, request a new project or session, or ask what to try next — I can also suggest camera settings while a camera's connected.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                        }
                        ForEach(cameraManager.assistantMessages) { message in
                            messageBubble(message).id(message.id)
                        }
                        if let pending = cameraManager.assistantPendingAction {
                            pendingActionCard(pending)
                        }
                        if cameraManager.isAssistantThinking {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Thinking…").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(12)
                }
                .onChange(of: cameraManager.assistantMessages.count) { _, _ in
                    guard let lastID = cameraManager.assistantMessages.last?.id else { return }
                    withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
                }
            }
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask the assistant…", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($isInputFocused)
                    .onSubmit(send)
                    .lineLimit(1...4)
                Button("Send", systemImage: "arrow.up.circle.fill") { send() }
                    .labelStyle(.iconOnly)
                    .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || cameraManager.isAssistantThinking)
            }
            .padding(10)
        }
        .background(.background)
    }

    private var header: some View {
        HStack {
            Label("Assistant", systemImage: "bubble.left.and.bubble.right").font(.headline)
            Spacer()
            if isDetachedWindow {
                Button("Dock", systemImage: "pin.fill") { cameraManager.isAssistantDetached = false }
                    .buttonStyle(.borderless)
                    .help("Return the assistant to the main window")
            } else {
                Button("Minimize", systemImage: "chevron.right") { cameraManager.isAssistantMinimized = true }
                    .buttonStyle(.borderless)
                    .help("Collapse the assistant to a thin rail")
                Button("Detach", systemImage: "arrow.up.left.and.arrow.down.right") { cameraManager.isAssistantDetached = true }
                    .buttonStyle(.borderless)
                    .help("Move the assistant into its own floating window")
                Button("Close", systemImage: "xmark") { cameraManager.isAssistantPanelVisible = false }
                    .buttonStyle(.borderless)
                    .help("Hide the assistant — reopen from the Skyformac menu")
            }
        }
        .padding(10)
    }

    private func send() {
        let text = inputText
        inputText = ""
        Task { await cameraManager.sendAssistantMessage(text) }
    }

    @ViewBuilder
    private func messageBubble(_ message: AssistantMessage) -> some View {
        HStack {
            if message.role == .assistant { Spacer(minLength: 24) }
            Text(message.text)
                .font(.callout)
                .padding(8)
                .background(
                    message.role == .user ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .textSelection(.enabled)
            if message.role == .user { Spacer(minLength: 24) }
        }
    }

    @ViewBuilder
    private func pendingActionCard(_ pending: AssistantPendingAction) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Proposed change", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.bold())
                .foregroundStyle(.orange)
            Text(pending.message).font(.caption)
            HStack {
                Button("Approve") { cameraManager.confirmAssistantAction() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Reject") { cameraManager.rejectAssistantAction() }
                    .controlSize(.small)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The always-visible collapsed state — a thin rail with a single expand button, so closing the
/// panel down to "out of the way" never means losing track of where it went.
struct AssistantMinimizedRail: View {
    var cameraManager: CameraManager

    var body: some View {
        VStack {
            Button("Expand Assistant", systemImage: "bubble.left.and.bubble.right") {
                cameraManager.isAssistantMinimized = false
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(.top, 10)
            Spacer()
        }
        .frame(width: 36)
        .background(.background.secondary)
    }
}
