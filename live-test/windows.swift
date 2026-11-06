// Lists one app's on-screen windows: `swift windows.swift <owner name>`.
// Prints "id x y width height layer" with top-left screen coordinates (what `screencapture -R` takes).
import CoreGraphics
import Foundation

let owner = CommandLine.arguments.dropFirst().first ?? "ContextGuardApp"
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerName as String] as? String) == owner {
    let id = w[kCGWindowNumber as String] as? Int ?? 0
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    print(id, Int(b["X"] ?? 0), Int(b["Y"] ?? 0), Int(b["Width"] ?? 0), Int(b["Height"] ?? 0), layer)
}
