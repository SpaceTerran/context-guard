import ContextGuardCore
import SwiftUI

/// The menu under the gauge in the menu bar.
struct MenuContent: View {
    let model: AppModel

    var body: some View {
        Toggle("Context Guard On", isOn: Binding(get: { model.config.enabled }, set: { model.setEnabled($0) }))
        let c = model.config
        let claude = "\(Format.tokens(c.askAt)) · Wait until \(Format.tokens(c.laterAt))"
        if model.showsCodex {
            Text("Claude Code: asks at \(claude)")
            Text("Codex: asks at \(c.codexAskPercent)% · Wait until \(c.codexLaterPercent)%")
        } else {
            Text("Asks at \(claude)")
        }
        Divider()
        let sessions = model.liveSessions
        if sessions.isEmpty {
            Text("No sessions running")
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
            let subtitle = model.subtitle(info)
            if !subtitle.isEmpty { Text(subtitle) }
            Divider()
            // Asks the session to save, then compacts it, even with Context Guard off or the tab unwatched.
            Button("Compact Now") { model.answer(info.id, .yes, from: .menu) }
                .disabled(!model.canCompactNow(info))
            if info.effectivePhase == .asking {
                let laterAt = model.thresholds(info).laterAt
                if info.state.tokens < laterAt {
                    Button("Wait until \(info.shortSize(laterAt))") { model.answer(info.id, .later, from: .menu) }
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
