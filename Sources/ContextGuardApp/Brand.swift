import SwiftUI

// The app's controls: flat surfaces, 1 px borders, radius 6 on controls and 8 on panels, and the
// same hover, focus and disabled look on every control.

/// A panel of rows under a caps header, like the brand's component cards.
struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(Theme.font(11, .bold))
                .tracking(1.1)
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .accessibilityAddTraits(.isHeader)
            Rule()
            content
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel).strokeBorder(Theme.border, lineWidth: 1))
    }
}

/// A 1 px line between rows.
struct Rule: View {
    var body: some View {
        Theme.border.frame(height: 1)
    }
}

/// A label on the left and its control on the right.
struct Row<Control: View>: View {
    let label: String
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(Theme.font(13))
                .foregroundStyle(Theme.heading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
    }
}

/// A note under a card, or inside one.
struct Note: View {
    let text: String
    var color: Color = Theme.muted

    init(_ text: String, color: Color = Theme.muted) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(Theme.font(12))
            .lineSpacing(4)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "✓ Installed" and the like: a status word in its semantic color.
struct StatusLabel: View {
    let text: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .accessibilityHidden(true)
            Text(text).font(Theme.font(13))
        }
        .foregroundStyle(color)
    }
}

// MARK: Switch

/// The on/off switch: a violet track when on. Square-cornered like every other control (the brand
/// keeps pills for counts). Still a Toggle to accessibility.
struct BrandSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        SwitchBody(configuration: configuration)
    }

    private struct SwitchBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let on = configuration.isOn
            Button {
                configuration.isOn.toggle()
            } label: {
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .fill(on ? (hovering ? Theme.primaryHover : Theme.primary) : (hovering ? Theme.border : Theme.hover))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .strokeBorder(on ? Color.clear : Theme.borderStrong, lineWidth: 1))
                    .frame(width: 38, height: 22)
                    .overlay(alignment: on ? .trailing : .leading) {
                        RoundedRectangle(cornerRadius: Theme.Radius.badge)
                            .fill(on ? Theme.onPrimary : Theme.muted)
                            .frame(width: 16, height: 16)
                            .padding(3)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: on)
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
            }
        }
    }
}

// MARK: Fields

/// The box around a field: the page's background, a 1 px edge, and a lavender ring when focused.
struct FieldBox: ViewModifier {
    var focused: Bool
    var invalid = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control)
        content
            .background(Theme.bg, in: shape)
            .overlay(shape.strokeBorder(focused ? Theme.accent : invalid ? Theme.danger : Theme.borderStrong, lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control + 3)
                .strokeBorder(Theme.accent.opacity(focused ? 0.3 : 0), lineWidth: 3)
                .padding(-3))
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}

/// One line of text in the brand's field.
struct BrandTextField: View {
    let label: String
    @Binding var text: String
    var prompt = ""
    var alignment: TextAlignment = .leading
    var invalid = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField(label, text: $text, prompt: Text(prompt).foregroundStyle(Theme.disabled))
            .labelsHidden()
            .textFieldStyle(.plain)
            .font(Theme.font(13))
            .foregroundStyle(Theme.heading)
            .multilineTextAlignment(alignment)
            .focused($focused)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .modifier(FieldBox(focused: focused, invalid: invalid))
            // A hidden label isn't read out, so name the field for VoiceOver (and the test harness).
            .accessibilityLabel(label)
    }
}

/// Several lines of text in the brand's field.
struct BrandTextEditor: View {
    let label: String
    @Binding var text: String
    var height: CGFloat = 84
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(Theme.font(13))
            .foregroundStyle(Theme.heading)
            .lineSpacing(3)
            .scrollContentBackground(.hidden)
            .focused($focused)
            .padding(.horizontal, 5)
            .padding(.vertical, 7)
            .frame(height: height)
            .modifier(FieldBox(focused: focused))
            .accessibilityLabel(label)
    }
}

/// A whole number with its unit and − | + buttons that step along multiples of `step`.
struct NumberField: View {
    let label: String
    /// 0 while the field doesn't hold a number.
    @Binding var value: Int
    let unit: String
    let step: Int
    let range: ClosedRange<Int>
    var invalid = false
    @State private var text = ""

    var body: some View {
        Row(label: label) {
            HStack(spacing: 8) {
                // Text, not a number field: a number field only takes what was typed on Return or
                // leaving it, so closing the window right after typing would drop it.
                BrandTextField(label: label, text: $text, alignment: .trailing, invalid: invalid)
                    .frame(width: 64)
                Text(unit)
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: 72, alignment: .leading)
                Steps(label: label, decrement: {
                    value = max((value - 1) / step * step, range.lowerBound)
                }, increment: {
                    value = min((value / step + 1) * step, range.upperBound)
                })
            }
        }
        .onAppear { text = String(value) }
        .onChange(of: text) { if typed != value { value = typed } }
        // The buttons changed it. An empty or half-typed field already reads as 0, so leave it be.
        .onChange(of: value) { if typed != value { text = String(value) } }
    }

    private var typed: Int { max(Int(text.trimmingCharacters(in: .whitespaces)) ?? 0, 0) }

    /// − | + joined in one bordered control.
    private struct Steps: View {
        let label: String
        let decrement: () -> Void
        let increment: () -> Void

        var body: some View {
            HStack(spacing: 0) {
                StepButton(symbol: "minus", help: "Less", action: decrement)
                Theme.borderStrong.frame(width: 1)
                StepButton(symbol: "plus", help: "More", action: increment)
            }
            .frame(height: 30)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.borderStrong, lineWidth: 1))
            // To VoiceOver it's a stepper.
            .accessibilityRepresentation {
                Stepper(label, onIncrement: increment, onDecrement: decrement)
            }
        }
    }

    private struct StepButton: View {
        let symbol: String
        let help: String
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.heading)
                    .frame(width: 26, height: 30)
                    .background(hovering ? Theme.hover : Color.clear)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(help)
        }
    }
}

// MARK: Buttons

/// Primary: a violet fill with bold white text, for the one thing to do. Secondary: a bordered
/// panel. Ghost: violet text only.
struct BrandButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost }
    var kind: Kind
    var height: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        BrandButton(configuration: configuration, kind: kind, height: height)
    }

    private struct BrandButton: View {
        let configuration: Configuration
        let kind: Kind
        let height: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.control)
            let active = hovering || configuration.isPressed
            configuration.label
                .font(Theme.font(13, kind == .primary ? .bold : .regular))
                .lineLimit(1)
                .foregroundStyle(foreground)
                .padding(.horizontal, kind == .ghost ? 10 : 14)
                .frame(minHeight: height)
                .background(background(active: active), in: shape)
                .overlay(shape.strokeBorder(kind == .secondary ? Theme.borderStrong : Color.clear, lineWidth: 1))
                .contentShape(shape)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: active)
        }

        private var foreground: Color {
            guard isEnabled else { return Theme.disabled }
            switch kind {
            case .primary: return Theme.onPrimary
            case .secondary: return Theme.heading
            case .ghost: return Theme.accent
            }
        }

        private func background(active: Bool) -> Color {
            switch kind {
            case .primary: return !isEnabled ? Theme.hover : active ? Theme.primaryHover : Theme.primary
            case .secondary: return isEnabled && active ? Theme.hover : Theme.panel
            case .ghost: return isEnabled && active ? Theme.hover : Color.clear
            }
        }
    }
}

// MARK: Tabs

/// Text tabs over a 1 px line; the selected one is bold with a 2 px lavender underline.
struct TabBar<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    let title: (Tab) -> String
    @Binding var selection: Tab

    var body: some View {
        HStack(spacing: 24) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                let selected = tab == selection
                Button { selection = tab } label: {
                    Text(title(tab))
                        .font(Theme.font(13, selected ? .bold : .regular))
                        .foregroundStyle(selected ? Theme.heading : Theme.muted)
                        .padding(.vertical, 10)
                        .overlay(alignment: .bottom) {
                            Theme.accent.frame(height: 2).opacity(selected ? 1 : 0)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                .help("⌘\(index + 1)")
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) { Rule() }
    }
}
