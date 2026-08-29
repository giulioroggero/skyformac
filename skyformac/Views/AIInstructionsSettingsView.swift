import SwiftUI

/// "All system instructions, for each model, page, and task, are visible in Settings and can be
/// updated by the user" — every distinct AI task in the app (session/project planning, the
/// sidebar chat, Planetary Post-Processing's stacking suggestions, Edit Image's assistant, AI
/// descriptions, tag suggestions, and the existing "suggest next session" skill) gets its own
/// editable instructions block here, backed by `AppSettings`. Each one is exactly the text
/// `OllamaPlanner` actually sends as that task's persona/behavior paragraph — the JSON
/// response-format scaffolding that follows it in code stays fixed, since editing that would
/// silently break response parsing rather than just changing tone/behavior.
struct AIInstructionsSettingsView: View {
    @State private var sessionPlanningInstructions = AppSettings.sessionPlanningInstructions
    @State private var projectPlanningInstructions = AppSettings.projectPlanningInstructions
    @State private var assistantChatInstructions = AppSettings.assistantChatInstructions
    @State private var planetaryStackingInstructions = AppSettings.planetaryStackingInstructions
    @State private var imageAssistantInstructions = AppSettings.imageAssistantInstructions
    @State private var summaryInstructions = AppSettings.summaryInstructions
    @State private var suggestTagsInstructions = AppSettings.suggestTagsInstructions
    @State private var sessionSuggestionSkill = AppSettings.sessionSuggestionSkill

    var body: some View {
        Form {
            instructionSection(
                title: "Ask AI to Plan… (Session)", caption: "Used by a session's own \"Ask AI to Plan…\" button.",
                text: $sessionPlanningInstructions, default: AppSettings.defaultSessionPlanningInstructions,
                onSave: { AppSettings.sessionPlanningInstructions = $0 }
            )
            instructionSection(
                title: "Ask AI to Plan… (Project)", caption: "Used by a project's own \"Ask AI to Plan…\" button.",
                text: $projectPlanningInstructions, default: AppSettings.defaultProjectPlanningInstructions,
                onSave: { AppSettings.projectPlanningInstructions = $0 }
            )
            instructionSection(
                title: "Sidebar AI Assistant", caption: "Used on every page the AI panel appears on — Home, Project, Session, Capture, Live Capture, Gallery, and Equipment.",
                text: $assistantChatInstructions, default: AppSettings.defaultAssistantChatInstructions,
                onSave: { AppSettings.assistantChatInstructions = $0 }
            )
            instructionSection(
                title: "Planetary Post-Processing — AI Suggest Settings", caption: "Used by \"AI Suggest Settings\" at the start of Planetary Post-Processing's stacking setup.",
                text: $planetaryStackingInstructions, default: AppSettings.defaultPlanetaryStackingInstructions,
                onSave: { AppSettings.planetaryStackingInstructions = $0 }
            )
            instructionSection(
                title: "Edit Image AI Assistant", caption: "Used by Edit Image's own AI Assistant chat, including AI Enhance.",
                text: $imageAssistantInstructions, default: AppSettings.defaultImageAssistantInstructions,
                onSave: { AppSettings.imageAssistantInstructions = $0 }
            )
            instructionSection(
                title: "Ask AI to Describe…", caption: "Used when writing a project/session description.",
                text: $summaryInstructions, default: AppSettings.defaultSummaryInstructions,
                onSave: { AppSettings.summaryInstructions = $0 }
            )
            instructionSection(
                title: "Suggest Tags with AI", caption: "Used when suggesting tags for a project or session.",
                text: $suggestTagsInstructions, default: AppSettings.defaultSuggestTagsInstructions,
                onSave: { AppSettings.suggestTagsInstructions = $0 }
            )
            instructionSection(
                title: "AI Skill: Suggest Next Session", caption: "Standing instructions folded into every \"suggest my next session\" request — tune what the AI favors (equipment, target types, repeat vs. variety) without touching a single prompt in code.",
                text: $sessionSuggestionSkill, default: AppSettings.defaultSessionSuggestionSkill,
                onSave: { AppSettings.sessionSuggestionSkill = $0 }
            )
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func instructionSection(
        title: String, caption: String, text: Binding<String>, default defaultValue: String, onSave: @escaping (String) -> Void
    ) -> some View {
        Section(title) {
            TextEditor(text: text)
                .font(.body)
                .frame(minHeight: 90)
                .onChange(of: text.wrappedValue) { _, newValue in onSave(newValue) }
            HStack {
                Spacer()
                Button("Reset to Default") {
                    text.wrappedValue = defaultValue
                    onSave(defaultValue)
                }
                .disabled(text.wrappedValue == defaultValue)
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
