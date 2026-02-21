import SwiftUI

func owLog(_ msg: String) {
    let line = "\(Date()): \(msg)\n"
    let path = "/tmp/openwhisper.log"
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile()
        if let data = line.data(using: .utf8) { fh.write(data) }
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
    }
}

@main
struct OpenWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            SettingsView()
                .environment(AppState.shared)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: AppState.shared.menuBarIcon)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(AppState.shared.menuBarIconColor)
            }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        owLog("applicationDidFinishLaunching called")
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            owLog("Starting setup...")
            await AppState.shared.setup()
        }
    }
}
