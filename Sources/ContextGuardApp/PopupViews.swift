import ContextGuardCore
import SwiftUI

/// The question: "Context at 302k … Compact this session?" with Turn Off, Wait, Compact. A Codex
/// session's sizes are shares of its window first: "Context at 62% (160k)".
struct QuestionView: View {
    let model: AppModel
    let sessionID: String

    var body: some View {
        if let info = model.session(sessionID) {
            content(info)
        }
    }

    private func content(_ info: SessionInfo) -> some View {
        let progress = model.questionProgress(info)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AppBadge(size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Context at \(model.sizeText(info))")
                        .font(Theme.font(14, .bold))
                        .foregroundStyle(Theme.heading)
                    Text(info.title)
                        .font(Theme.font(13))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    let subtitle = model.subtitle(info)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(Theme.font(12))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                // Hiding a question that's about to compact by itself would hide that.
                if progress == .question, model.autoYesDeadline(info) == nil {
                    CloseButton(help: "Hide until it asks again (the menu can show it)") { model.hideQuestion(sessionID) }
                }
            }
            if progress == .question {
                question(info)
            } else {
                status(progress, info)
            }
        }
        .panelCard()
    }

    @ViewBuilder
    private func question(_ info: SessionInfo) -> some View {
        let laterAt = model.thresholds(info).laterAt
        let pastLater = info.state.tokens >= laterAt
        VStack(alignment: .leading, spacing: 6) {
            Text(questionText(info))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .help(model.config.message)
            if let deadline = model.autoYesDeadline(info) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 6) {
                        Image(systemName: "timer")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .accessibilityHidden(true)
                        Text(countdownText(info, deadline: deadline, now: context.date))
                            .foregroundStyle(Theme.muted)
                    }
                }
            }
        }
        .font(Theme.font(12))
        HStack(spacing: 8) {
            Button("Turn Off") { model.turnOffFromPopup() }
                .buttonStyle(BrandButtonStyle(kind: .ghost))
                .help("Stop asking and stop compacting by itself until you turn Context Guard back on")
            Spacer(minLength: 0)
            if pastLater {
                Button("Not Now") { model.answer(sessionID, .skip, from: .popup) }
                    .buttonStyle(BrandButtonStyle(kind: .secondary))
                    .help("Don't ask again until this session compacts")
            } else {
                Button("Wait until \(info.shortSize(laterAt))") { model.answer(sessionID, .later, from: .popup) }
                    .buttonStyle(BrandButtonStyle(kind: .secondary))
                    .help("Compact by itself when this session reaches \(info.size(laterAt))")
            }
            Button("Compact") { model.answer(sessionID, .yes, from: .popup) }
                .buttonStyle(BrandButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .help("Asks it to save first: \u{201C}\(model.config.message)\u{201D}")
        }
    }

    private func countdownText(_ info: SessionInfo, deadline: Date, now: Date) -> String {
        let left = Int(deadline.timeIntervalSince(now).rounded(.up))
        if left > 0 { return "Compacts in \(Format.seconds(left)) unless you answer" }
        // It goes out at the session's next step, or now if it can be reached.
        guard info.isIdle, !info.reachableNow else { return "Starting…" }
        return info.host == .codex ? "Starts \(info.host.whenOutOfReach)" : "Starts when this session next runs"
    }

    private func questionText(_ info: SessionInfo) -> String {
        let base = "Compact this session? It saves its work first."
        // Rare: no background hook is waiting (it timed out), so an idle session hears it on its next
        // turn; a Codex session no terminal shows hears it once one does.
        guard info.isIdle, !info.reachableNow else { return base }
        if info.host == .codex { return base + " No terminal shows it, so it starts when one does." }
        return base + " It's idle, so it starts when it next runs."
    }

    private func status(_ progress: QuestionProgress, _ info: SessionInfo) -> some View {
        HStack(spacing: 8) {
            // One fixed slot, so the text stays put as the spinner turns into a check.
            Group {
                switch progress {
                case .nextStep, .waking:
                    Spinner()
                case .sent:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                case .nextRun, .scheduled:
                    Image(systemName: "clock").foregroundStyle(Theme.muted)
                case .question, .closed:
                    EmptyView()
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 18, height: 18)
            Text(statusText(progress, info))
                .foregroundStyle(Theme.text)
        }
        .font(Theme.font(12))
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
    }

    private func statusText(_ progress: QuestionProgress, _ info: SessionInfo) -> String {
        switch progress {
        case .nextStep: return "Asking it to save at its next step…"
        case .waking: return "Asking it to save…"
        case .nextRun: return "Asks it to save \(info.host.whenOutOfReach)"
        case .sent: return "Asked it to save, then it compacts"
        case .scheduled(let at): return "Compacts by itself at \(info.size(at))"
        case .question, .closed: return ""
        }
    }
}

/// A short message that closes by itself: an automatic send, a compaction, turning off.
struct NoticeView: View {
    let symbol: String
    var tone: FollowUpText.Tone = .accent
    let title: String
    let detail: String
    var caption: String = ""
    /// A reason wraps; a name and folder stays on one line, cut in the middle.
    var captionWraps = false
    var close: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AppBadge(size: 38, symbol: symbol, color: Theme.color(tone))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Theme.font(14, .bold))
                    .foregroundStyle(Theme.heading)
                Text(detail)
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                if !caption.isEmpty {
                    Text(caption)
                        .font(Theme.font(12))
                        .lineSpacing(2)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(captionWraps ? 3 : 1)
                        .truncationMode(captionWraps ? .tail : .middle)
                        .fixedSize(horizontal: false, vertical: captionWraps)
                }
            }
            Spacer(minLength: 0)
            CloseButton(help: "Close", action: close)
        }
        .panelCard()
    }
}

extension View {
    /// The popups' and notices' card: an overlay panel, a flat fill with a 1 px edge. The
    /// window draws the one shadow overlays get.
    func panelCard() -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.panel)
        return padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(width: PanelController.width, alignment: .leading)
            .background(Theme.panel, in: shape)
            .overlay(shape.strokeBorder(Theme.borderStrong, lineWidth: 1))
            .tint(Theme.primary)
    }
}

/// The app's icon in miniature: the gauge on the brand's tile, or a notice's symbol in its tone.
struct AppBadge: View {
    var size: CGFloat
    var symbol = "gauge.with.needle.fill"
    var color: Color = Theme.planet

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
        shape
            .fill(Theme.bg)
            .overlay(shape.strokeBorder(Theme.border, lineWidth: 1))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(color)
            }
            .accessibilityHidden(true)
    }
}

/// A lavender arc that turns: the system spinner on macOS is gray whatever its tint.
struct Spinner: View {
    var size: CGFloat = 14
    @State private var turning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: turning)
            .onAppear { turning = true }
            .accessibilityLabel("Working")
    }
}

struct CloseButton: View {
    var help: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(hovering ? Theme.heading : Theme.muted)
                .frame(width: 22, height: 22)
                .background(hovering ? Theme.hover : Color.clear, in: RoundedRectangle(cornerRadius: Theme.Radius.badge))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel("Close")
    }
}
