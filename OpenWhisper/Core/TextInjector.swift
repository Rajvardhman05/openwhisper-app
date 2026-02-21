import AppKit
import CoreGraphics
import ApplicationServices

final class TextInjector: @unchecked Sendable {

    /// Copy text to the system clipboard
    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Paste text into the target app
    func pasteText(_ text: String, targetApp: NSRunningApplication? = nil) {
        // Filter junk
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned.hasPrefix("[BLANK") {
            owLog("[TextInjector] Skipping empty/junk text: \(cleaned)")
            return
        }

        owLog("[TextInjector] Starting paste (\(cleaned.count) chars)")

        // Always put text on clipboard first
        copyToClipboard(cleaned)

        // Activate the target app
        if let app = targetApp {
            owLog("[TextInjector] Activating: \(app.localizedName ?? "?") (pid \(app.processIdentifier))")
            app.activate()
        }

        // Wait for app to come to front, then paste via CGEvent
        let delay: TimeInterval = 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            // Log what's actually frontmost right now
            let frontmost = NSWorkspace.shared.frontmostApplication
            owLog("[TextInjector] Frontmost at paste time: \(frontmost?.localizedName ?? "none") (pid \(frontmost?.processIdentifier ?? 0))")
            owLog("[TextInjector] AXIsProcessTrusted: \(AXIsProcessTrusted())")

            // Method 1: CGEvent Cmd+V (works in terminals, editors, everywhere IF accessibility is granted)
            owLog("[TextInjector] Posting CGEvent Cmd+V...")
            self.simulateCmdV()

            // Method 2: After a short delay, also try AXUIElement for apps where CGEvent fails
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
                // Check if clipboard still has our text (if it does, paste probably didn't work)
                let clipText = NSPasteboard.general.string(forType: .string)
                owLog("[TextInjector] Post-paste clipboard check: \(clipText == cleaned ? "unchanged (paste may have failed)" : "changed (paste likely worked)")")
            }
        }
    }

    /// Simulate Cmd+V via CGEvent
    private func simulateCmdV() {
        let vKeyCode: CGKeyCode = 9

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: false) else {
            owLog("[TextInjector] CGEvent creation failed!")
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        usleep(80_000)
        keyUp.post(tap: .cghidEventTap)
        owLog("[TextInjector] CGEvent Cmd+V posted")
    }
}
