import ContextGuardCore
import SwiftUI

/// The menu under the gauge in the menu bar.
struct MenuContent: View {
    let model: AppModel

    var body: some View {
        Toggle("Context Guard On", isOn: Binding(get: { model.config.enabled }, set: { model.setEnabled($0) }))
        Text("Asks at \(Format.tokens(model.config.askAt)) · Wait until \(Format.tokens(model.config.laterAt))")
        Divider()
        let sessions = model.liveSessions
        if sessions.isEmpty {
            Text("No Claude Code sessions running")
        } else {
            Section("Sessions") {
                ForEach(sessions) { info in
                    SessionMenu(model: model, info: info)
                }
            }
        }
        Divider()
        Button("Settings…") { model.openSettings() }
            .keyboardShortcut(",")
        Button("Quit Context Guard") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

struct SessionMenu: View {
    let model: AppModel
    let info: SessionInfo

    var body: some View {
        Menu {
            Text(model.statusText(info))
            if let followUp = model.followUpText(info) { Text(followUp) }
            if !info.subtitle.isEmpty { Text(info.subtitle) }
            Divider()
            // Asks the session to save, then compacts it, even with Context Guard off or the tab
            // unwatched. On a session that's done saving and waiting on background work, compacts
            // it without waiting.
            Button("Compact Now") { model.compactNow(info.id) }
                .disabled(!model.canCompactNow(info))
            if info.effectivePhase == .asking {
                if info.state.tokens < model.config.laterAt {
                    Button("Wait until \(Format.tokens(model.config.laterAt))") { model.answer(info.id, .later, from: .menu) }
                } else {
                    Button("Not Now") { model.answer(info.id, .skip, from: .menu) }
                }
                Button("Show the Question") { model.showQuestion(info.id) }
            }
            Divider()
            Toggle("Watch This Session", isOn: Binding(get: { !info.muted }, set: { model.setWatched(info.id, $0) }))
        } label: {
            Label(Self.shortened(info.title), systemImage: symbol)
        }
        .badge(Text(model.tokensText(info)).monospacedDigit())
    }

    private var symbol: String {
        if info.muted, !model.isSending(info) { return "eye.slash" }
        switch info.effectivePhase {
        case .watching: return "circle"
        case .asking: return "questionmark.circle"
        case .later: return "clock"
        case .queued: return "paperplane"
        case .sent: return info.state.confirmedAt != nil ? "checkmark.circle" : "paperplane"
        case .skipped: return "minus.circle"
        }
    }

    /// Menus don't truncate; keep one long title from widening the whole menu.
    static func shortened(_ s: String, max: Int = 44) -> String {
        s.count <= max ? s : String(s.prefix(max - 1)) + "…"
    }
}
