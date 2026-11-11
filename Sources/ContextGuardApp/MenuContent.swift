import ContextGuardCore
import SwiftUI

/// The menu under the gauge in the menu bar.
struct MenuContent: View {
    let model: AppModel

    var body: some View {
        Toggle(Words.Menu.on, isOn: Binding(get: { model.config.enabled }, set: { model.setEnabled($0) }))
        ForEach(Display.thresholdLines(model.config, showsCodex: model.showsCodex), id: \.self) { Text($0) }
        Divider()
        let sessions = model.liveSessions
        if sessions.isEmpty {
            Text(Words.Menu.noSessions)
        } else {
            Section(Words.Menu.sessions) {
                ForEach(sessions) { info in
                    SessionMenu(model: model, info: info)
                }
            }
        }
        Divider()
        Button(Words.Menu.settings) { model.openSettings() }
            .keyboardShortcut(",")
        Button(Words.Menu.quit) { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

struct SessionMenu: View {
    let model: AppModel
    let info: SessionInfo

    var body: some View {
        Menu {
            let now = Date()
            Text(info.statusText(model.config))
            if let followUp = info.followUpText(model.config, now: now) { Text(followUp) }
            let subtitle = info.toolSubtitle
            if !subtitle.isEmpty { Text(subtitle) }
            Divider()
            // Asks the session to save, then compacts it, even with Context Guard off or the tab unwatched.
            Button(Words.Menu.compactNow) { model.answer(info.id, .yes, from: .menu) }
                .disabled(!info.canCompactNow)
            if info.effectivePhase == .asking {
                let deferral = info.deferral(model.config)
                Button(info.label(for: deferral)) { model.answer(info.id, deferral.action, from: .menu) }
                Button(Words.Menu.showQuestion) { model.showQuestion(info.id) }
            }
            Divider()
            Toggle(Words.Menu.watchThisSession, isOn: Binding(get: { !info.muted }, set: { model.setWatched(info.id, $0) }))
        } label: {
            Label(Display.shortened(info.title), systemImage: info.symbol.systemName)
        }
        .badge(Text(info.tokensText).monospacedDigit())
    }
}
