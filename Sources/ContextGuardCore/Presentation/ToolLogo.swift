import Foundation

/// The mark of the tool a session runs in, drawn next to it in the menu, its popups and its notices
/// in both apps: Anthropic for Claude Code, OpenAI for Codex, Cursor for Cursor (`design/logos`).
///
/// Each is path data on a 24-point square, y down, in the path markup the Windows app hands XAML as
/// it is: `F1` (nonzero fill), then `M`, `L`, `C` and `Z` with absolute `x,y` points, separated by
/// spaces. `ToolLogoTests` writes it from the SVGs (`ToolLogo.g.swift`).
public enum ToolLogo {
    /// The side of the square the paths are drawn on.
    public static let size = 24.0

    /// The mark for a tool's sessions.
    public static func path(_ host: SessionHost) -> String {
        switch host {
        case .claude: return anthropic
        case .codex: return openAI
        case .cursor: return cursor
        }
    }

    public enum Step: Equatable, Sendable {
        case move(x: Double, y: Double)
        case line(x: Double, y: Double)
        case curve(x1: Double, y1: Double, x2: Double, y2: Double, x: Double, y: Double)
        case close
    }

    /// A path's steps, for drawing it. Anything that isn't the markup above ends it there.
    public static func steps(_ path: String) -> [Step] {
        var steps: [Step] = []
        var command: Character?
        var points: [(Double, Double)] = []
        for token in path.split(separator: " ") {
            if token == "F1" { continue }
            if token.count == 1, let c = token.first, c.isLetter {
                guard points.isEmpty else { return steps }
                if c == "Z" {
                    steps.append(.close)
                    command = nil
                } else {
                    command = c
                }
                continue
            }
            let xy = token.split(separator: ",")
            guard xy.count == 2, let x = Double(xy[0]), let y = Double(xy[1]) else { return steps }
            points.append((x, y))
            switch (command, points.count) {
            case ("M", 1): steps.append(.move(x: x, y: y)); points = []
            case ("L", 1): steps.append(.line(x: x, y: y)); points = []
            case ("C", 3):
                steps.append(.curve(x1: points[0].0, y1: points[0].1, x2: points[1].0, y2: points[1].1, x: x, y: y))
                points = []
            case ("C", _): break
            default: return steps
            }
        }
        return steps
    }
}
