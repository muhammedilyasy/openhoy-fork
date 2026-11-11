import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = AppState.shared
        state.start()

        let statusBar = StatusBarController()
        statusBar.onOpenSettings = { SettingsWindowController.shared.show() }
        statusBar.onStopScreenRecording = { ScreenRecordCoordinator.shared.stop() }
        self.statusBar = statusBar

        ChatPanelController.shared.onScreenRecord = { chat in
            ScreenRecordCoordinator.shared.begin(for: chat)
        }

        // First run (or no Full Disk Access yet): show the setup window once access is known.
        state.$access
            .removeDuplicates()
            .filter { $0 != .unknown }
            .first()
            .receive(on: RunLoop.main)
            .sink { access in
                if case .denied = access { SettingsWindowController.shared.show() }
                else if state.pinnedGUIDs.isEmpty { SettingsWindowController.shared.show() }
            }
            .store(in: &cancellables)

        // Development hooks (used with scripts/make-demo-db.py).
        let env = ProcessInfo.processInfo.environment
        if let look = env["OPENHOY_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: look == "dark" ? .darkAqua : .aqua)
        }
        if env["OPENHOY_OPEN_FIRST"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let guid = state.pinnedGUIDs.first, let rect = statusBar.anchorRect(for: guid) else { return }
                ChatPanelController.shared.show(chatGUID: guid, anchor: rect)
                if let text = env["OPENHOY_DRAFT"] { state.composer(for: guid).text = text }
                if let files = env["OPENHOY_ATTACH"] {
                    state.composer(for: guid).addFiles(files.split(separator: ",").map { URL(fileURLWithPath: String($0)) })
                }
            }
        }
        if env["OPENHOY_PASTETEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { ChatPanelController.shared.pasteTest() }
        }
        if let path = env["OPENHOY_SETTINGS_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                SettingsWindowController.shared.show()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    SettingsWindowController.shared.snapshot(to: URL(fileURLWithPath: path))
                }
            }
        }
        #if DEBUG
        if env["OPENHOY_DROPSHELF_TEST"] != nil {
            let path = env["OPENHOY_DROPSHELF_TEST"].flatMap { $0.isEmpty || $0 == "1" ? nil : $0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                statusBar.dropShelfTest(snapshot: path.map { URL(fileURLWithPath: $0) })
            }
        }
        #endif
        if env["OPENHOY_SELFTEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { statusBar.selfTest() }
        }
        if let path = env["OPENHOY_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                ChatPanelController.shared.snapshot(to: URL(fileURLWithPath: path))
                statusBar.snapshot(to: URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("menubar.png"))
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return true
    }
}
