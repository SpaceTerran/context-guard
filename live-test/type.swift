// Types into one app only: `swift type.swift <pid> <text>` types at the focused field's cursor in that
// process. The key events go to the pid, never to whatever app is in front, so a test can't type
// into someone's terminal. `ui-demo.sh type` focuses the field and selects its text first.
import CoreGraphics
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 2, let pid = pid_t(args[0]) else { print("usage: type.swift <pid> <text>"); exit(1) }
let source = CGEventSource(stateID: .privateState)

func key(_ code: CGKeyCode, text: String? = nil) {
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
        if let text {
            let units = Array(text.utf16)
            e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        }
        e.postToPid(pid)
        usleep(20_000)
    }
}

for ch in args[1] { key(0, text: String(ch)) }
