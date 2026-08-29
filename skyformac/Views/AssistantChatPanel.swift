import AppKit
import SwiftUI

/// "A chat on the right bar of all pages" — a `.sheet`-free sidebar embedded by `RootView`
/// alongside whichever page is currently showing (the Projects browser or the live camera view),
/// so it's the same one panel/conversation regardless of where the user is, not a separate chat
/// per page. Any proposed change (`CameraManager.assistantPendingAction`) always shows its own
/// Approve/Reject card rather than being applied the moment the model suggests it.
/// "The AI button must be visible not only in Home's top bar, but on every page" — one shared
/// `ToolbarContent` used from `DashboardHomeView`, `ContentView`, `ProjectDetailPane`,
/// `SessionDetailPane`, and `CaptureDetailPage`, instead of copy-pasting the same visibility
/// condition and action five times. Only shown when the assistant isn't already sitting
/// somewhere reachable — the panel's own "Close"/"Detach"/"Minimize" controls are otherwise the
/// only way back, and none of those are reachable once the panel itself is gone.
struct OpenAssistantToolbarItem: ToolbarContent {
    var cameraManager: CameraManager
    /// `false` on `ContentView` (the live camera page) — `RootView` only ever embeds the docked
    /// sidebar while `activeSession == nil`, and `CameraManager.isAssistantPanelVisible`'s own
    /// `didSet` immediately forces `isAssistantDetached` back to `true` during a live session
    /// regardless, so asking for the docked sidebar there would just get silently overridden.
    /// Skipping the assignment entirely (rather than setting it and having it bounce back) keeps
    /// this button's action honest about what it's actually going to do.
    var isEmbeddedSidebarAvailable: Bool = true

    var body: some ToolbarContent {
        ToolbarItem {
            if !cameraManager.isAssistantPanelVisible || cameraManager.isAssistantDetached || cameraManager.isAssistantMinimized {
                Button("Open Assistant", systemImage: "bubble.left.and.bubble.right") {
                    cameraManager.isAssistantPanelVisible = true
                    if isEmbeddedSidebarAvailable { cameraManager.isAssistantDetached = false }
                    cameraManager.isAssistantMinimized = false
                }
                .accessibilityIdentifier("OpenAssistantToolbarButton")
                .help("Open the AI assistant")
            }
        }
    }
}

struct AssistantChatPanel: View {
    var cameraManager: CameraManager
    /// `true` when hosted inside `AssistantChatPanelController`'s floating `NSPanel` — hides the
    /// Minimize/Detach/Close controls that only make sense for the embedded sidebar, and shows a
    /// "Dock" button instead.
    var isDetachedWindow: Bool = false

    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool
    @State private var availableModels: [String] = []
    @State private var isRenamingChatSession = false
    @State private var renamingSessionID: AIChatSession.ID?
    @State private var renameText = ""
    @State private var isConfirmingDeleteAllChats = false

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
                                Spacer()
                                Button("Stop", systemImage: "stop.fill") { cameraManager.stopAssistantMessage() }
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(.borderless)
                                    .help("Stop waiting for a reply")
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
        .task { await refreshAvailableModels() }
    }

    /// Docking back into the sidebar only makes sense while the camera view isn't running — "in
    /// camera mode the AI is only detached" is a hard rule, not just where it happens to start.
    private var canDock: Bool { cameraManager.activeSession == nil }

    private var header: some View {
        HStack {
            Label("AI", systemImage: "bubble.left.and.bubble.right").font(.headline)
            HelpLinkButton(cameraManager: cameraManager, topicID: "config-reference", sectionID: "setting.assistant")
            modelMenu
            Spacer()
            historyMenu
            if isDetachedWindow {
                if canDock {
                    Button("Dock", systemImage: "pin.fill") { cameraManager.isAssistantDetached = false }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Return the AI panel to the main window")
                }
                Button("Close", systemImage: "xmark") { cameraManager.isAssistantPanelVisible = false }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Hide the AI panel — reopen from the Skyformac menu")
            } else {
                Button("Minimize", systemImage: "chevron.right") { cameraManager.isAssistantMinimized = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Collapse the AI panel to a thin rail")
                Button("Detach", systemImage: "arrow.up.left.and.arrow.down.right") { cameraManager.isAssistantDetached = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Move the AI panel into its own floating window")
                Button("Close", systemImage: "xmark") { cameraManager.isAssistantPanelVisible = false }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Hide the AI panel — reopen from the Skyformac menu")
            }
        }
        .padding(10)
    }

    /// "Allow to choose the AI model … in the AI assistant" — a compact menu next to the title
    /// rather than a full settings-shaped picker, showing the currently pinned model (or "Auto")
    /// and letting it be changed without leaving the chat. Models are fetched lazily (`.task` on
    /// the panel's own body) rather than requiring a trip through Settings' "Test Connection" first.
    private var modelMenu: some View {
        Menu {
            Button("Auto (recommended)") {
                cameraManager.updateOllamaConfiguration(serverURL: cameraManager.ollamaPlanner.baseURL, model: nil)
            }
            if !availableModels.isEmpty {
                Divider()
                ForEach(availableModels, id: \.self) { model in
                    Button(model) {
                        cameraManager.updateOllamaConfiguration(serverURL: cameraManager.ollamaPlanner.baseURL, model: model)
                    }
                }
            }
        } label: {
            Text(cameraManager.ollamaPlanner.model ?? "Auto")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose which Ollama model the AI uses")
    }

    /// "The user can create a new AI session and see the history, recalling and continuing a
    /// conversation" — one compact menu (not two separate header buttons, which pushed the
    /// sidebar's minimum width past CI's 1024×768 virtual display) holding "New Chat" plus one
    /// entry per saved conversation (most-recently-updated first, via `CameraManager.chatSessions`),
    /// each with its own Open/Rename/Delete submenu so switching, renaming, and cleaning up old
    /// chats never needs a separate page.
    private var historyMenu: some View {
        Menu {
            Button("New Chat", systemImage: "square.and.pencil") { cameraManager.startNewChatSession() }
            if !cameraManager.chatSessions.isEmpty {
                Divider()
                ForEach(cameraManager.chatSessions) { session in
                    Menu(session.title) {
                        Button("Open") { cameraManager.switchToChatSession(session.id) }
                        Button("Rename…") {
                            renameText = session.title
                            renamingSessionID = session.id
                            isRenamingChatSession = true
                        }
                        Button("Delete", role: .destructive) { cameraManager.deleteChatSession(session.id) }
                    }
                }
                Divider()
                Button("Delete All Chats…", systemImage: "trash", role: .destructive) {
                    isConfirmingDeleteAllChats = true
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Browse previous AI conversations")
        .popover(isPresented: $isRenamingChatSession) { renameSheetContent }
        .confirmationDialog(
            "Delete all \(cameraManager.chatSessions.count) saved chats? This can't be undone.",
            isPresented: $isConfirmingDeleteAllChats, titleVisibility: .visible
        ) {
            Button("Delete All Chats", role: .destructive) { cameraManager.deleteAllChatSessions() }
        }
    }

    private var renameSheetContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rename Chat").font(.headline)
            TextField("Title", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commitRename)
            HStack {
                Spacer()
                Button("Cancel") { isRenamingChatSession = false }
                Button("Save", action: commitRename).buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 260)
    }

    private func commitRename() {
        guard let id = renamingSessionID else { return }
        cameraManager.renameChatSession(id, to: renameText)
        isRenamingChatSession = false
    }

    private func refreshAvailableModels() async {
        availableModels = (try? await cameraManager.ollamaPlanner.installedModels()) ?? []
    }

    private func send() {
        let text = inputText
        inputText = ""
        cameraManager.startAssistantMessage(text)
    }

    /// See `ChatBubbleRendering` — shared with Edit Image's own AI Assistant bar so the two don't
    /// keep separate copies of the same Markdown handling/bubble styling.
    private func messageBubble(_ message: AssistantMessage) -> some View {
        ChatBubbleRendering.bubble(message)
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
            Button("Expand AI", systemImage: "bubble.left.and.bubble.right") {
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

/// A draggable divider — "allow to resize the assistant sidebar" — dragging left/right grows or
/// shrinks `width` (clamped to a sane range so the panel can't be dragged down to nothing, or out
/// wide enough to swallow the whole window). Only shown while the panel is embedded and expanded;
/// the minimized rail has a fixed width, and the detached floating window already gets a native
/// resizable edge for free from `NSPanel` itself.
struct AssistantResizeHandle: View {
    @Binding var width: Double
    @State private var widthAtDragStart: Double?
    /// Defaults to the assistant sidebar's own original range — `ControlsPanelView`'s resize
    /// handle (`ContentView.swift`) passes its own, wider range instead, since that panel's
    /// default width is deliberately much smaller.
    var widthRange: ClosedRange<Double> = 260...600

    var body: some View {
        Divider()
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { isHovering in
                if isHovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = widthAtDragStart ?? width
                        widthAtDragStart = start
                        // The handle sits on the sidebar's leading edge — dragging left (a
                        // negative `translation.width`) should grow the panel, so the delta is
                        // subtracted, not added.
                        width = min(max(start - value.translation.width, widthRange.lowerBound), widthRange.upperBound)
                    }
                    .onEnded { _ in widthAtDragStart = nil }
            )
    }
}
