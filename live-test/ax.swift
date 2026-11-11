// Works one app's controls through accessibility, found by their label, so a test never sends keys
// or clicks to whatever app is in front:
//
//   ax <pid> press <label> [n]  press the button or switch with this title or description
//   ax <pid> clear <label> [n]  focus the text field or text area with this label and empty it
//   ax <pid> list               print every control's role and label (to find the right one)
//
// When several controls share a label, n picks the nth one in `list` order (default 1).
//
// `ui-demo.sh` compiles it once to .build/ax.
import ApplicationServices
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2, let pid = pid_t(args[0]) else {
    print("usage: ax <pid> press|clear <label> [n] | ax <pid> list")
    exit(1)
}
let app = AXUIElementCreateApplication(pid)

func attribute(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
}

func string(_ e: AXUIElement, _ name: String) -> String? { attribute(e, name) as? String }

func children(_ e: AXUIElement) -> [AXUIElement] { attribute(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }

/// Every element under the app's windows, depth first.
func all(_ e: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 40 else { return [] }
    return [e] + children(e).flatMap { all($0, depth: depth + 1) }
}

func labels(_ e: AXUIElement) -> [String] {
    [kAXTitleAttribute, kAXDescriptionAttribute, kAXLabelValueAttribute, kAXHelpAttribute].compactMap { string(e, $0) }.filter { !$0.isEmpty }
}

let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
let elements = windows.flatMap { all($0) }

func find(_ label: String, roles: Set<String>) -> AXUIElement? {
    let n = args.count > 3 ? Int(args[3]) ?? 0 : 1
    let matches = elements.filter { e in
        guard let role = string(e, kAXRoleAttribute), roles.contains(role) else { return false }
        return labels(e).contains(label)
    }
    return n >= 1 && n <= matches.count ? matches[n - 1] : nil
}

switch args[1] {
case "list":
    for e in elements {
        let role = string(e, kAXRoleAttribute) ?? "?"
        let names = labels(e)
        if !names.isEmpty { print("\(role)\t\(names.joined(separator: " | "))") }
    }
case "press":
    guard (3...4).contains(args.count), let e = find(args[2], roles: ["AXButton", "AXCheckBox", "AXSwitch", "AXRadioButton"]) else {
        print("no button or switch labelled \(args.dropFirst(2).joined(separator: " #"))")
        exit(1)
    }
    exit(AXUIElementPerformAction(e, kAXPressAction as CFString) == .success ? 0 : 1)
case "clear":
    guard (3...4).contains(args.count), let e = find(args[2], roles: ["AXTextField", "AXTextArea"]) else {
        print("no text field labelled \(args.dropFirst(2).joined(separator: " #"))")
        exit(1)
    }
    AXUIElementSetAttributeValue(e, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    exit(AXUIElementSetAttributeValue(e, kAXValueAttribute as CFString, "" as CFString) == .success ? 0 : 1)
default:
    print("unknown command \(args[1])")
    exit(1)
}
