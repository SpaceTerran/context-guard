import AppKit
import ContextGuardCore
import SwiftUI

@main
struct ContextGuardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // `ContextGuardApp --render-icon <folder.iconset>`: build.sh draws the app icon this way.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-icon"), i + 1 < args.count {
            exit(AppIcon.writeIconset(to: URL(fileURLWithPath: args[i + 1])) ? 0 : 1)
        }
        // `ContextGuard --login-item on|off`: install.sh turns opening at login on, and off again
        // before an uninstall. Only works from the .app (the login item is this bundle).
        if let i = args.firstIndex(of: "--login-item"), i + 1 < args.count {
            do {
                try LoginItem.set(args[i + 1] == "on")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("couldn't change the login item: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: delegate.model)
        } label: {
            MenuBarLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel(paths: .fromEnvironment())

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One copy at a time: a second launch (another path, an old build) quits right away.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != .current }) {
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        model.start()
    }

    /// Opening the app again (Finder, Spotlight, `open`) shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.openSettings()
        return false
    }
}

struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        Image(nsImage: MenuBarIcon.image(on: model.config.enabled, asking: model.hasQuestion))
            .accessibilityLabel(model.config.enabled ? "Context Guard" : "Context Guard (off)")
    }
}
