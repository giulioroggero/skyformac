import SwiftUI

/// Shared chat-bubble rendering — the sidebar's own `AssistantChatPanel` and Edit Image's AI
/// Assistant bar (`SingleImagePostProcessingView.aiAssistantBar`) both show the exact same
/// `AssistantMessage` shape, so this is the one place that owns "how a chat message actually
/// looks," rather than each view keeping its own copy of the same Markdown handling/bubble
/// styling to drift out of sync.
/// `@MainActor` — unlike an instance method on a `View`-conforming type (implicitly main-actor
/// isolated), a plain `enum`'s `static func`s aren't, and building SwiftUI views (`Spacer`,
/// `HStack`, ...) from a nonisolated context is a real Swift 6 concurrency error under strict
/// checking — confirmed live: this built fine locally but failed in CI, whose Xcode enforces it.
@MainActor
enum ChatBubbleRendering {
    /// "Render better the output of AI" — the model routinely answers in Markdown (`**M31**`,
    /// bullet lists), which a plain `Text(message.text)` showed as literal asterisks/dashes
    /// instead of real formatting. `.inlineOnlyPreservingWhitespace` renders bold/italic/inline
    /// code and keeps the model's own line breaks exactly as written (a paragraph of prose with a
    /// few bolded terms, the actual use case here) without attempting block-level layout (real
    /// bulleted lists, headings) that `Text` can't render distinctly anyway. Falls back to the raw
    /// string on a parse failure — malformed Markdown from a small model shouldn't ever make a
    /// reply disappear.
    static func markdownText(_ raw: String) -> Text {
        if let attributed = try? AttributedString(markdown: raw, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(raw)
    }

    @ViewBuilder
    static func bubble(_ message: AssistantMessage) -> some View {
        HStack {
            if message.role == .assistant { Spacer(minLength: 24) }
            markdownText(message.text)
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
}
