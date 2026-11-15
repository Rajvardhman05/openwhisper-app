import SwiftUI
import UserNotifications

/// Log file holds dictated text, so it lives in the user's Library (not world-readable /tmp), owner-only (0600).
let owLogPath: String = {
    let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        .appendingPathComponent("Logs/OpenWhisper")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    return dir.appendingPathComponent("openwhisper.log").path
}()

func owLog(_ msg: String) {
    let line = "\(Date()): \(msg)\n"
    if let fh = FileHandle(forWritingAtPath: owLogPath) {
        fh.seekToEndOfFile()
        if let data = line.data(using: .utf8) { fh.write(data) }
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: owLogPath, contents: line.data(using: .utf8),
                                       attributes: [.posixPermissions: 0o600])
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

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        owLog("applicationDidFinishLaunching called")
        NSApplication.shared.setActivationPolicy(.accessory)

        // Set delegate so notifications show even when app is in foreground
        UNUserNotificationCenter.current().delegate = self

        Task { @MainActor in
            owLog("Starting setup...")
            await AppState.shared.setup()
        }
    }

    // Show notifications as banners even when the app is active/foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
