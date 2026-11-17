import Foundation
import XCTest
@testable import ContextGuardCore

/// The tools' marks for both apps, taken from `design/logos/*.svg`, which stay the one place they're
/// set. Each SVG's path is rewritten as absolute moves, lines and cubic curves (its arcs, quadratic
/// and smooth curves, and relative steps worked out), so the Mac (a CGPath) and Windows (XAML path
/// markup) draw the same shapes from the same numbers. Two files are written from them and checked
/// byte for byte:
/// - `Sources/ContextGuardCore/Presentation/ToolLogo.g.swift` for the Mac;
/// - `windows/ContextGuard.Feed/ToolLogos.g.cs` for Windows.
///
/// After a change to an SVG, `CONTEXT_GUARD_UPDATE_CONTRACT=1 swift test --filter ToolLogoTests`
/// rewrites them; read the diff before committing it.
final class ToolLogoTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let updating = ProcessInfo.processInfo.environment["CONTEXT_GUARD_UPDATE_CONTRACT"] == "1"

    /// Each mark: its file, its name in `ToolLogo`, and the tool whose sessions show it.
    static let marks: [(file: String, name: String, host: SessionHost)] = [
        ("anthropic", "anthropic", .claude),
        ("openai", "openAI", .codex),
        ("cursor", "cursor", .cursor),
    ]

    func testEveryToolHasAMark() {
        XCTAssertEqual(Set(Self.marks.map(\.host)), Set(SessionHost.allCases))
        for mark in Self.marks {
            XCTAssertEqual(ToolLogo.path(mark.host), try Self.markup(mark.file), mark.file)
        }
    }

    func testTheMacsFile() throws {
        var lines = ["// Written by ToolLogoTests from design/logos/*.svg: don't edit.", "", "extension ToolLogo {"]
        for mark in Self.marks {
            lines.append("    /// `design/logos/\(mark.file).svg`")
            lines.append("    static let \(mark.name) = \"\(try Self.markup(mark.file))\"")
        }
        lines.append("}")
        try check("Sources/ContextGuardCore/Presentation/ToolLogo.g.swift", lines.joined(separator: "\n") + "\n")
    }

    func testTheWindowsFile() throws {
        var lines = [
            "// Written by ToolLogoTests from design/logos/*.svg (as Core's ToolLogo.g.swift): don't edit.",
            "// A .g.cs file counts as generated, which turns nullable annotations off unless it says otherwise.",
            "#nullable enable",
            "namespace ContextGuard.Feed;",
            "",
            "/// <summary>",
            "/// The mark of the tool a session runs in (<see cref=\"Tool.Id\"/>), as XAML path markup on a 24 DIP square: the",
            "/// same shapes the Mac draws. contract/ui/names.json lists every tool; a test checks this covers them all.",
            "/// </summary>",
            "public static class ToolLogos",
            "{",
            "    /// <summary>The side of the square the paths are drawn on.</summary>",
            "    public const double Size = 24;",
            "",
            "    static readonly Dictionary<string, string> ByTool = new(StringComparer.Ordinal)",
            "    {",
        ]
        for mark in Self.marks {
            lines.append("        // design/logos/\(mark.file).svg")
            lines.append("        [\"\(mark.host.rawValue)\"] = \"\(try Self.markup(mark.file))\",")
        }
        lines += [
            "    };",
            "",
            "    /// <summary>The tools this build has a mark for.</summary>",
            "    public static IReadOnlyCollection<string> Tools => ByTool.Keys;",
            "",
            "    /// <summary>The mark for a tool; none for a newer program's tool this build doesn't know.</summary>",
            "    public static string? For(string tool) => ByTool.TryGetValue(tool, out var path) ? path : null;",
            "}",
        ]
        try check("windows/ContextGuard.Feed/ToolLogos.g.cs", lines.joined(separator: "\n") + "\n")
    }

    /// Every mark reads back into steps that stay on its square, and draws something.
    func testTheMarksStayOnTheirSquare() throws {
        for mark in Self.marks {
            let path = ToolLogo.path(mark.host)
            let steps = ToolLogo.steps(path)
            XCTAssertEqual(steps.count, path.split(separator: " ").filter { $0.count == 1 }.count, mark.file)
            var xs: [Double] = [], ys: [Double] = []
            for step in steps {
                switch step {
                case .move(let x, let y), .line(let x, let y): xs.append(x); ys.append(y)
                case .curve(_, _, _, _, let x, let y): xs.append(x); ys.append(y)
                case .close: break
                }
            }
            XCTAssertGreaterThan(xs.count, 3, mark.file)
            XCTAssertGreaterThanOrEqual(xs.min() ?? -1, -0.01, mark.file)
            XCTAssertGreaterThanOrEqual(ys.min() ?? -1, -0.01, mark.file)
            XCTAssertLessThanOrEqual(xs.max() ?? 99, ToolLogo.size + 0.01, mark.file)
            XCTAssertLessThanOrEqual(ys.max() ?? 99, ToolLogo.size + 0.01, mark.file)
            // Simple Icons fit each mark to the square: its longer side touches both edges.
            XCTAssertGreaterThan(max((xs.max() ?? 0) - (xs.min() ?? 0), (ys.max() ?? 0) - (ys.min() ?? 0)), 23.5, mark.file)
        }
    }

    func testArcsBecomeCurvesThatEndWhereTheArcDoes() throws {
        // A half circle of radius 1 from (0,1) to (2,1), over the top: two quarter curves.
        let half = try Self.normalize("M0 1A1 1 0 0 1 2 1")
        XCTAssertEqual(half.filter { if case .curve = $0 { return true } else { return false } }.count, 2)
        guard case .curve(_, _, _, _, let x, let y)? = half.last, case .curve(_, _, _, _, let mx, let my) = half[1] else {
            return XCTFail("no curves")
        }
        XCTAssertEqual(x, 2, accuracy: 1e-9)
        XCTAssertEqual(y, 1, accuracy: 1e-9)
        XCTAssertEqual(mx, 1, accuracy: 1e-9)
        XCTAssertEqual(my, 0, accuracy: 1e-9)
        // Relative steps, H and V, a number run together ("1.5.5" is 1.5 and .5) and implicit lines after a move.
        XCTAssertEqual(try Self.normalize("m1 1h2v2l-1.5.5 1 1zm1 0 1 1"), [
            .move(x: 1, y: 1), .line(x: 3, y: 1), .line(x: 3, y: 3), .line(x: 1.5, y: 3.5), .line(x: 2.5, y: 4.5), .close,
            .move(x: 2, y: 1), .line(x: 3, y: 2),
        ])
    }

    // MARK: Reading the SVGs

    /// A mark as path markup, three decimals at most.
    static func markup(_ file: String) throws -> String {
        let svg = try String(contentsOf: root.appendingPathComponent("design/logos/\(file).svg"), encoding: .utf8)
        guard svg.contains("viewBox=\"0 0 24 24\""), !svg.contains("fill-rule"), !svg.contains("transform") else {
            throw Failure("\(file).svg: expected one path on a 24-unit square, nonzero fill, no transform")
        }
        let paths = svg.matches(of: /<path d="([^"]+)"/)
        guard paths.count == 1, let d = paths.first?.1 else { throw Failure("\(file).svg: expected one path") }
        var parts = ["F1"]
        for step in try normalize(String(d)) {
            switch step {
            case .move(let x, let y): parts += ["M", point(x, y)]
            case .line(let x, let y): parts += ["L", point(x, y)]
            case .curve(let x1, let y1, let x2, let y2, let x, let y): parts += ["C", point(x1, y1), point(x2, y2), point(x, y)]
            case .close: parts.append("Z")
            }
        }
        return parts.joined(separator: " ")
    }

    static func point(_ x: Double, _ y: Double) -> String { "\(number(x)),\(number(y))" }

    static func number(_ v: Double) -> String {
        var s = String(format: "%.3f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// An SVG path's `d` as absolute moves, lines and cubic curves.
    static func normalize(_ d: String) throws -> [ToolLogo.Step] {
        var scanner = PathScanner(Array(d.utf8))
        var steps: [ToolLogo.Step] = []
        var x = 0.0, y = 0.0, startX = 0.0, startY = 0.0
        // The last curve's second control point, for S (cubic) and T (quadratic).
        var cubicControl: (Double, Double)?, quadControl: (Double, Double)?
        var command: UInt8 = 0

        func curve(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ ex: Double, _ ey: Double) {
            steps.append(.curve(x1: x1, y1: y1, x2: x2, y2: y2, x: ex, y: ey))
            x = ex; y = ey
        }

        while true {
            scanner.skipSeparators()
            guard let next = scanner.peek() else { break }
            if PathScanner.isCommand(next) {
                command = next
                scanner.advance()
                if command == UInt8(ascii: "Z") || command == UInt8(ascii: "z") {
                    steps.append(.close)
                    x = startX; y = startY
                    cubicControl = nil; quadControl = nil
                    continue
                }
            } else if command == 0 || command == UInt8(ascii: "Z") || command == UInt8(ascii: "z") {
                throw Failure("numbers without a command at \(scanner.position)")
            }
            let relative = command >= UInt8(ascii: "a")
            let (ox, oy) = relative ? (x, y) : (0, 0)
            var nextCubic: (Double, Double)?, nextQuad: (Double, Double)?
            switch command | 0x20 {
            case UInt8(ascii: "m"):
                x = ox + (try scanner.number()); y = oy + (try scanner.number())
                startX = x; startY = y
                steps.append(.move(x: x, y: y))
                // More points after a move are lines.
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")
            case UInt8(ascii: "l"):
                x = ox + (try scanner.number()); y = oy + (try scanner.number())
                steps.append(.line(x: x, y: y))
            case UInt8(ascii: "h"):
                x = ox + (try scanner.number())
                steps.append(.line(x: x, y: y))
            case UInt8(ascii: "v"):
                y = oy + (try scanner.number())
                steps.append(.line(x: x, y: y))
            case UInt8(ascii: "c"):
                let x1 = ox + (try scanner.number()), y1 = oy + (try scanner.number())
                let x2 = ox + (try scanner.number()), y2 = oy + (try scanner.number())
                let ex = ox + (try scanner.number()), ey = oy + (try scanner.number())
                curve(x1, y1, x2, y2, ex, ey)
                nextCubic = (x2, y2)
            case UInt8(ascii: "s"):
                let (x1, y1) = cubicControl.map { (2 * x - $0.0, 2 * y - $0.1) } ?? (x, y)
                let x2 = ox + (try scanner.number()), y2 = oy + (try scanner.number())
                let ex = ox + (try scanner.number()), ey = oy + (try scanner.number())
                curve(x1, y1, x2, y2, ex, ey)
                nextCubic = (x2, y2)
            case UInt8(ascii: "q"), UInt8(ascii: "t"):
                let (qx, qy): (Double, Double)
                if command | 0x20 == UInt8(ascii: "q") {
                    qx = ox + (try scanner.number()); qy = oy + (try scanner.number())
                } else {
                    (qx, qy) = quadControl.map { (2 * x - $0.0, 2 * y - $0.1) } ?? (x, y)
                }
                let ex = ox + (try scanner.number()), ey = oy + (try scanner.number())
                let (sx, sy) = (x, y)
                curve(sx + 2 / 3 * (qx - sx), sy + 2 / 3 * (qy - sy), ex + 2 / 3 * (qx - ex), ey + 2 / 3 * (qy - ey), ex, ey)
                nextQuad = (qx, qy)
            case UInt8(ascii: "a"):
                let rx = try scanner.number(), ry = try scanner.number(), rotation = try scanner.number()
                let large = try scanner.flag(), sweep = try scanner.flag()
                let ex = ox + (try scanner.number()), ey = oy + (try scanner.number())
                for c in arc(from: (x, y), rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep, to: (ex, ey)) {
                    steps.append(c)
                }
                x = ex; y = ey
            default:
                throw Failure("unknown command \(Character(UnicodeScalar(command)))")
            }
            cubicControl = nextCubic
            quadControl = nextQuad
        }
        return steps
    }

    /// An SVG arc as cubic curves of a quarter turn or less (SVG 1.1, F.6.5 and F.6.6).
    static func arc(from p0: (Double, Double), rx: Double, ry: Double, rotation: Double, large: Bool, sweep: Bool,
                    to p: (Double, Double)) -> [ToolLogo.Step] {
        if p0 == p { return [] }
        var rx = abs(rx), ry = abs(ry)
        if rx == 0 || ry == 0 { return [.line(x: p.0, y: p.1)] }
        let phi = rotation * .pi / 180, cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.0 - p.0) / 2, dy = (p0.1 - p.1) / 2
        let x1 = cosPhi * dx + sinPhi * dy, y1 = -sinPhi * dx + cosPhi * dy
        let lambda = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
        if lambda > 1 { rx *= lambda.squareRoot(); ry *= lambda.squareRoot() }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        let coef = (large == sweep ? -1.0 : 1.0) * max(0, num / den).squareRoot()
        let cx1 = coef * rx * y1 / ry, cy1 = -coef * ry * x1 / rx
        let cx = cosPhi * cx1 - sinPhi * cy1 + (p0.0 + p.0) / 2
        let cy = sinPhi * cx1 + cosPhi * cy1 + (p0.1 + p.1) / 2
        func angle(_ u: (Double, Double), _ v: (Double, Double)) -> Double {
            atan2(u.0 * v.1 - u.1 * v.0, u.0 * v.0 + u.1 * v.1)
        }
        let u = ((x1 - cx1) / rx, (y1 - cy1) / ry), v = ((-x1 - cx1) / rx, (-y1 - cy1) / ry)
        let theta = angle((1, 0), u)
        var delta = angle(u, v)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }
        let n = max(1, Int((abs(delta) / (.pi / 2) - 1e-9).rounded(.up)))
        let step = delta / Double(n)
        let t = 4.0 / 3.0 * tan(step / 4)
        func map(_ ux: Double, _ uy: Double) -> (Double, Double) {
            (cx + rx * ux * cosPhi - ry * uy * sinPhi, cy + rx * ux * sinPhi + ry * uy * cosPhi)
        }
        var curves: [ToolLogo.Step] = []
        for i in 0..<n {
            let a1 = theta + Double(i) * step, a2 = a1 + step
            let c1 = map(cos(a1) - t * sin(a1), sin(a1) + t * cos(a1))
            let c2 = map(cos(a2) + t * sin(a2), sin(a2) - t * cos(a2))
            let end = i == n - 1 ? p : map(cos(a2), sin(a2))
            curves.append(.curve(x1: c1.0, y1: c1.1, x2: c2.0, y2: c2.1, x: end.0, y: end.1))
        }
        return curves
    }

    struct PathScanner {
        let bytes: [UInt8]
        var position = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        static func isCommand(_ b: UInt8) -> Bool { "MmLlHhVvCcSsQqTtAaZz".utf8.contains(b) }

        func peek() -> UInt8? { position < bytes.count ? bytes[position] : nil }
        mutating func advance() { position += 1 }

        mutating func skipSeparators() {
            while let b = peek(), b == UInt8(ascii: " ") || b == UInt8(ascii: ",") || b == 0x0A || b == 0x0D || b == 0x09 {
                advance()
            }
        }

        /// A number: sign, digits, one decimal point, exponent. "1.5.5" is 1.5, then .5.
        mutating func number() throws -> Double {
            skipSeparators()
            let start = position
            if let b = peek(), b == UInt8(ascii: "-") || b == UInt8(ascii: "+") { advance() }
            var dot = false, digits = false
            while let b = peek() {
                if b >= UInt8(ascii: "0"), b <= UInt8(ascii: "9") { digits = true; advance() }
                else if b == UInt8(ascii: "."), !dot { dot = true; advance() }
                else { break }
            }
            if digits, let b = peek(), b == UInt8(ascii: "e") || b == UInt8(ascii: "E") {
                advance()
                if let s = peek(), s == UInt8(ascii: "-") || s == UInt8(ascii: "+") { advance() }
                while let b = peek(), b >= UInt8(ascii: "0"), b <= UInt8(ascii: "9") { advance() }
            }
            guard digits, let v = Double(String(decoding: bytes[start..<position], as: UTF8.self)) else {
                throw Failure("expected a number at \(start)")
            }
            return v
        }

        /// An arc's flag: one digit, which needn't be followed by a separator.
        mutating func flag() throws -> Bool {
            skipSeparators()
            guard let b = peek(), b == UInt8(ascii: "0") || b == UInt8(ascii: "1") else { throw Failure("expected a flag at \(position)") }
            advance()
            return b == UInt8(ascii: "1")
        }
    }

    func check(_ path: String, _ text: String, line: UInt = #line) throws {
        let url = Self.root.appendingPathComponent(path)
        if Self.updating {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            return
        }
        guard let expected = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("\(path) is missing: run with CONTEXT_GUARD_UPDATE_CONTRACT=1", line: line)
            return
        }
        XCTAssertEqual(text, expected.replacingOccurrences(of: "\r\n", with: "\n"),
                       "\(path) differs from design/logos: run with CONTEXT_GUARD_UPDATE_CONTRACT=1 and read the diff", line: line)
    }
}
